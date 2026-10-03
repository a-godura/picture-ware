// Package api implements the HTTP API Lambda handler for /trips.
package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

// Store is the subset of trip and photo persistence the API needs.
type Store interface {
	CreateTrip(ctx context.Context, t photos.Trip) error
	ListTrips(ctx context.Context, userID string) ([]photos.Trip, error)
	GetTrip(ctx context.Context, tripID string) (photos.Trip, error)
	IsMember(ctx context.Context, tripID, userID string) (bool, error)
	// PutPhoto creates a pending photo and counts it against lim; it returns
	// an error wrapping photos.ErrDailyLimit, ErrUserStorage or
	// ErrTotalStorage (and writes nothing) when a limit would be exceeded.
	PutPhoto(ctx context.Context, p photos.Photo, lim photos.Limits) error
	// ReleaseStaleReservations frees userID's storage reservations for
	// uploads started before cutoff that never landed.
	ReleaseStaleReservations(ctx context.Context, userID string, cutoff time.Time) (int, error)
	GetPhoto(ctx context.Context, tripID, id string) (photos.Photo, error)
	// ListReadyPhotos returns one page of ready photos in listing order
	// (photos.ListOrder) and the cursor of the next page ("" if none).
	ListReadyPhotos(ctx context.Context, tripID string, limit int, cursor string) ([]photos.Photo, string, error)
	DeletePhoto(ctx context.Context, p photos.Photo) error
}

// Objects deletes stored photo files.
type Objects interface {
	Delete(ctx context.Context, key string) error
}

// Presigner creates presigned S3 requests.
type Presigner interface {
	PresignUpload(ctx context.Context, key, contentType string) (photos.Upload, error)
	PresignGet(ctx context.Context, key string) (string, error)
}

// Handler serves the /trips API.
type Handler struct {
	Store     Store
	Presigner Presigner
	Objects   Objects
	NewID     func() string
	Now       func() time.Time
	Limits    photos.Limits // upload quotas for POST /trips/{tripId}/photos
}

// TripView is a trip in API responses.
type TripView struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	StartDate string    `json:"startDate"`
	EndDate   *string   `json:"endDate"`
	CreatedBy string    `json:"createdBy"`
	CreatedAt time.Time `json:"createdAt"`
}

// TripList is the 200 body of GET /trips.
type TripList struct {
	Trips []TripView `json:"trips"`
}

// CreateResponse is the 201 body of POST /trips/{tripId}/photos.
type CreateResponse struct {
	ID     string        `json:"id"`
	Upload photos.Upload `json:"upload"`
}

// PhotoView is one entry in the GET /trips/{tripId}/photos response.
type PhotoView struct {
	ID         string     `json:"id"`
	Lat        float64    `json:"lat"`
	Lng        float64    `json:"lng"`
	TakenAt    *time.Time `json:"takenAt"`
	CreatedAt  time.Time  `json:"createdAt"`
	UploaderID string     `json:"uploaderId"`
	ImageURL   string     `json:"imageUrl"`
}

// ListResponse is the 200 body of GET /trips/{tripId}/photos.
type ListResponse struct {
	Photos     []PhotoView `json:"photos"`
	NextCursor *string     `json:"nextCursor"`
}

// Page size of GET /trips/{tripId}/photos (?limit=).
const (
	DefaultPageSize = 200
	MaxPageSize     = 500
)

const maxBodyBytes = 4 << 10

// UserID returns the caller's Cognito user id (the "sub" claim) from the
// HTTP API JWT authorizer context. It also requires token_use=access, so an
// ID token (whose "aud" would also satisfy the authorizer) is rejected.
// ok is false when the claims are missing or unusable.
func UserID(req events.APIGatewayV2HTTPRequest) (string, bool) {
	a := req.RequestContext.Authorizer
	if a == nil || a.JWT == nil {
		return "", false
	}
	claims := a.JWT.Claims
	if claims["token_use"] != "access" {
		return "", false
	}
	sub := claims["sub"]
	if !photos.ValidID(sub) {
		return "", false
	}
	return sub, true
}

// Handle routes an HTTP API (payload v2) request. API Gateway's JWT
// authorizer rejects unauthenticated requests before they get here; a request
// without usable claims is still answered 401 rather than trusted.
func (h *Handler) Handle(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	switch req.RouteKey {
	case "GET /trips", "POST /trips", "GET /trips/{tripId}",
		"GET /trips/{tripId}/photos", "POST /trips/{tripId}/photos", "DELETE /trips/{tripId}/photos/{photoId}":
	default:
		return errorResponse(http.StatusNotFound, "not found"), nil
	}
	userID, ok := UserID(req)
	if !ok {
		slog.WarnContext(ctx, "request without usable JWT claims", "route", req.RouteKey)
		return errorResponse(http.StatusUnauthorized, "unauthorized"), nil
	}
	switch req.RouteKey {
	case "GET /trips":
		return h.listTrips(ctx, userID), nil
	case "POST /trips":
		return h.createTrip(ctx, userID, req), nil
	}

	// Everything below is inside one trip: only its members may see it, and
	// to anyone else it doesn't exist.
	tripID := req.PathParameters["tripId"]
	if resp, ok := h.requireMember(ctx, tripID, userID); !ok {
		return resp, nil
	}
	switch req.RouteKey {
	case "GET /trips/{tripId}":
		return h.getTrip(ctx, tripID), nil
	case "GET /trips/{tripId}/photos":
		return h.listPhotos(ctx, tripID, req.QueryStringParameters), nil
	case "POST /trips/{tripId}/photos":
		return h.createPhoto(ctx, tripID, userID, req), nil
	}
	return h.deletePhoto(ctx, tripID, userID, req.PathParameters["photoId"]), nil
}

func (h *Handler) requireMember(ctx context.Context, tripID, userID string) (events.APIGatewayV2HTTPResponse, bool) {
	if !photos.ValidID(tripID) {
		return errorResponse(http.StatusNotFound, "trip not found"), false
	}
	ok, err := h.Store.IsMember(ctx, tripID, userID)
	if err != nil {
		slog.ErrorContext(ctx, "membership check failed", "tripId", tripID, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error"), false
	}
	if !ok {
		return errorResponse(http.StatusNotFound, "trip not found"), false
	}
	return events.APIGatewayV2HTTPResponse{}, true
}

func (h *Handler) listTrips(ctx context.Context, userID string) events.APIGatewayV2HTTPResponse {
	trips, err := h.Store.ListTrips(ctx, userID)
	if err != nil {
		slog.ErrorContext(ctx, "list trips failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	// Newest trips first.
	sort.SliceStable(trips, func(i, j int) bool {
		if trips[i].StartDate != trips[j].StartDate {
			return trips[i].StartDate > trips[j].StartDate
		}
		return trips[i].CreatedAt.After(trips[j].CreatedAt)
	})
	out := TripList{Trips: make([]TripView, 0, len(trips))}
	for _, t := range trips {
		out.Trips = append(out.Trips, tripView(t))
	}
	return jsonResponse(http.StatusOK, out)
}

func (h *Handler) createTrip(ctx context.Context, userID string, req events.APIGatewayV2HTTPRequest) events.APIGatewayV2HTTPResponse {
	var in photos.CreateTripRequest
	if resp, ok := decodeBody(req, &in, "body must be a JSON object with name, startDate and optional endDate"); !ok {
		return resp
	}
	in, err := in.Validate()
	if err != nil {
		return errorResponse(http.StatusBadRequest, err.Error())
	}
	t := photos.Trip{
		ID: h.NewID(), Name: in.Name, StartDate: in.StartDate, EndDate: in.EndDate,
		CreatedBy: userID, CreatedAt: h.Now().UTC(),
	}
	if err := h.Store.CreateTrip(ctx, t); err != nil {
		slog.ErrorContext(ctx, "create trip failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	return jsonResponse(http.StatusCreated, tripView(t))
}

func (h *Handler) getTrip(ctx context.Context, tripID string) events.APIGatewayV2HTTPResponse {
	t, err := h.Store.GetTrip(ctx, tripID)
	if errors.Is(err, photos.ErrNotFound) {
		return errorResponse(http.StatusNotFound, "trip not found")
	}
	if err != nil {
		slog.ErrorContext(ctx, "get trip failed", "tripId", tripID, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	return jsonResponse(http.StatusOK, tripView(t))
}

func (h *Handler) createPhoto(ctx context.Context, tripID, userID string, req events.APIGatewayV2HTTPRequest) events.APIGatewayV2HTTPResponse {
	var in photos.CreateRequest
	if resp, ok := decodeBody(req, &in, "body must be a JSON object with lat, lng, contentType and optional takenAt"); !ok {
		return resp
	}
	takenAt, err := in.Validate()
	if err != nil {
		return errorResponse(http.StatusBadRequest, err.Error())
	}
	p := photos.Photo{
		TripID:      tripID,
		ID:          h.NewID(),
		UploaderID:  userID,
		Lat:         *in.Lat,
		Lng:         *in.Lng,
		TakenAt:     takenAt,
		ContentType: in.ContentType,
		Status:      photos.StatusPending,
		CreatedAt:   h.Now().UTC(),
	}
	if err := h.putPhoto(ctx, p); err != nil {
		for _, q := range []error{photos.ErrDailyLimit, photos.ErrUserStorage, photos.ErrTotalStorage} {
			if errors.Is(err, q) {
				slog.WarnContext(ctx, "upload quota reached", "user", userID, "quota", q.Error())
				return errorResponse(http.StatusTooManyRequests, q.Error())
			}
		}
		slog.ErrorContext(ctx, "store put failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	up, err := h.Presigner.PresignUpload(ctx, photos.ObjectKey(tripID, p.ID), p.ContentType)
	if err != nil {
		slog.ErrorContext(ctx, "presign upload failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	return jsonResponse(http.StatusCreated, CreateResponse{ID: p.ID, Upload: up})
}

// putPhoto stores a pending photo within the upload quotas. When a storage
// cap is hit it first releases the user's reservations for uploads that
// never landed, and retries once if that freed anything.
func (h *Handler) putPhoto(ctx context.Context, p photos.Photo) error {
	err := h.Store.PutPhoto(ctx, p, h.Limits)
	if !errors.Is(err, photos.ErrUserStorage) && !errors.Is(err, photos.ErrTotalStorage) {
		return err
	}
	n, rerr := h.Store.ReleaseStaleReservations(ctx, p.UploaderID, h.Now().Add(-photos.ReservationTTL))
	if rerr != nil {
		slog.ErrorContext(ctx, "release stale reservations failed", "err", rerr)
	}
	if n == 0 {
		return err
	}
	slog.InfoContext(ctx, "released stale reservations", "user", p.UploaderID, "count", n)
	return h.Store.PutPhoto(ctx, p, h.Limits)
}

// listPhotos returns one page of the trip's ready photos, in capture order
// (photos without a capture time last, by upload time) across pages.
func (h *Handler) listPhotos(ctx context.Context, tripID string, query map[string]string) events.APIGatewayV2HTTPResponse {
	limit := DefaultPageSize
	if s, ok := query["limit"]; ok {
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 || n > MaxPageSize {
			return errorResponse(http.StatusBadRequest, fmt.Sprintf("limit must be an integer from 1 to %d", MaxPageSize))
		}
		limit = n
	}
	items, next, err := h.Store.ListReadyPhotos(ctx, tripID, limit, query["cursor"])
	if errors.Is(err, photos.ErrInvalidCursor) {
		return errorResponse(http.StatusBadRequest, "invalid cursor")
	}
	if err != nil {
		slog.ErrorContext(ctx, "list failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	out := ListResponse{Photos: make([]PhotoView, 0, len(items))}
	if next != "" {
		out.NextCursor = &next
	}
	for _, p := range items {
		url, err := h.Presigner.PresignGet(ctx, photos.ObjectKey(tripID, p.ID))
		if err != nil {
			slog.ErrorContext(ctx, "presign get failed", "id", p.ID, "err", err)
			return errorResponse(http.StatusInternalServerError, "internal error")
		}
		out.Photos = append(out.Photos, PhotoView{
			ID: p.ID, Lat: p.Lat, Lng: p.Lng, TakenAt: p.TakenAt, CreatedAt: p.CreatedAt,
			UploaderID: p.UploaderID, ImageURL: url,
		})
	}
	return jsonResponse(http.StatusOK, out)
}

// deletePhoto lets a photo's uploader remove it: the file first, then the
// record, so a failure part-way leaves the record in place and the client
// can retry.
func (h *Handler) deletePhoto(ctx context.Context, tripID, userID, id string) events.APIGatewayV2HTTPResponse {
	if !photos.ValidID(id) {
		return errorResponse(http.StatusNotFound, "photo not found")
	}
	p, err := h.Store.GetPhoto(ctx, tripID, id)
	if errors.Is(err, photos.ErrNotFound) {
		return errorResponse(http.StatusNotFound, "photo not found")
	}
	if err != nil {
		slog.ErrorContext(ctx, "get photo failed", "id", id, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	if p.UploaderID != userID {
		return errorResponse(http.StatusForbidden, "only the person who uploaded a photo can delete it")
	}
	if err := h.Objects.Delete(ctx, photos.ObjectKey(tripID, id)); err != nil {
		slog.ErrorContext(ctx, "delete object failed", "id", id, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	err = h.Store.DeletePhoto(ctx, p)
	if errors.Is(err, photos.ErrNotFound) {
		return errorResponse(http.StatusNotFound, "photo not found")
	}
	if err != nil {
		slog.ErrorContext(ctx, "store delete failed", "id", id, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	return events.APIGatewayV2HTTPResponse{StatusCode: http.StatusNoContent}
}

func tripView(t photos.Trip) TripView {
	v := TripView{ID: t.ID, Name: t.Name, StartDate: t.StartDate, CreatedBy: t.CreatedBy, CreatedAt: t.CreatedAt}
	if t.EndDate != "" {
		end := t.EndDate
		v.EndDate = &end
	}
	return v
}

// decodeBody strictly decodes a (possibly base64) JSON body into v.
func decodeBody(req events.APIGatewayV2HTTPRequest, v any, hint string) (events.APIGatewayV2HTTPResponse, bool) {
	body := []byte(req.Body)
	if req.IsBase64Encoded {
		// HTTP API base64-encodes bodies it doesn't recognise as text.
		var err error
		if body, err = base64.StdEncoding.DecodeString(req.Body); err != nil {
			return errorResponse(http.StatusBadRequest, "invalid request body"), false
		}
	}
	if len(body) > maxBodyBytes {
		return errorResponse(http.StatusRequestEntityTooLarge, "request body too large"), false
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return errorResponse(http.StatusBadRequest, hint), false
	}
	return events.APIGatewayV2HTTPResponse{}, true
}

type errorBody struct {
	Error string `json:"error"`
}

func errorResponse(status int, msg string) events.APIGatewayV2HTTPResponse {
	return jsonResponse(status, errorBody{Error: msg})
}

func jsonResponse(status int, v any) events.APIGatewayV2HTTPResponse {
	b, err := json.Marshal(v)
	if err != nil {
		status, b = http.StatusInternalServerError, []byte(`{"error":"internal error"}`)
	}
	return events.APIGatewayV2HTTPResponse{
		StatusCode: status,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(b),
	}
}
