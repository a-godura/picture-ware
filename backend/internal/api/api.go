// Package api implements the HTTP API Lambda handler for /photos.
package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

// Store is the subset of photo persistence the API needs.
type Store interface {
	Put(ctx context.Context, p photos.Photo) error
	ListReady(ctx context.Context) ([]photos.Photo, error)
}

// Presigner creates presigned S3 requests.
type Presigner interface {
	PresignUpload(ctx context.Context, key, contentType string) (photos.Upload, error)
	PresignGet(ctx context.Context, key string) (string, error)
}

// Handler serves POST /photos and GET /photos.
type Handler struct {
	Store     Store
	Presigner Presigner
	NewID     func() string
	Now       func() time.Time
}

// CreateResponse is the 201 body of POST /photos.
type CreateResponse struct {
	ID     string        `json:"id"`
	Upload photos.Upload `json:"upload"`
}

// PhotoView is one entry in the GET /photos response.
type PhotoView struct {
	ID        string     `json:"id"`
	Lat       float64    `json:"lat"`
	Lng       float64    `json:"lng"`
	TakenAt   *time.Time `json:"takenAt"`
	CreatedAt time.Time  `json:"createdAt"`
	ImageURL  string     `json:"imageUrl"`
}

// ListResponse is the 200 body of GET /photos.
type ListResponse struct {
	Photos []PhotoView `json:"photos"`
}

const maxBodyBytes = 4 << 10

// Handle routes an HTTP API (payload v2) request.
func (h *Handler) Handle(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	switch req.RouteKey {
	case "POST /photos":
		return h.create(ctx, req), nil
	case "GET /photos":
		return h.list(ctx), nil
	default:
		return errorResponse(http.StatusNotFound, "not found"), nil
	}
}

func (h *Handler) create(ctx context.Context, req events.APIGatewayV2HTTPRequest) events.APIGatewayV2HTTPResponse {
	body := []byte(req.Body)
	if req.IsBase64Encoded {
		// HTTP API base64-encodes bodies it doesn't recognise as text.
		var err error
		if body, err = base64.StdEncoding.DecodeString(req.Body); err != nil {
			return errorResponse(http.StatusBadRequest, "invalid request body")
		}
	}
	if len(body) > maxBodyBytes {
		return errorResponse(http.StatusRequestEntityTooLarge, "request body too large")
	}
	var in photos.CreateRequest
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return errorResponse(http.StatusBadRequest, "body must be a JSON object with lat, lng, contentType and optional takenAt")
	}
	takenAt, err := in.Validate()
	if err != nil {
		return errorResponse(http.StatusBadRequest, err.Error())
	}

	p := photos.Photo{
		ID:          h.NewID(),
		Lat:         *in.Lat,
		Lng:         *in.Lng,
		TakenAt:     takenAt,
		ContentType: in.ContentType,
		Status:      photos.StatusPending,
		CreatedAt:   h.Now().UTC(),
	}
	if err := h.Store.Put(ctx, p); err != nil {
		slog.ErrorContext(ctx, "store put failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	up, err := h.Presigner.PresignUpload(ctx, photos.ObjectKey(p.ID), p.ContentType)
	if err != nil {
		slog.ErrorContext(ctx, "presign upload failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	return jsonResponse(http.StatusCreated, CreateResponse{ID: p.ID, Upload: up})
}

func (h *Handler) list(ctx context.Context) events.APIGatewayV2HTTPResponse {
	items, err := h.Store.ListReady(ctx)
	if err != nil {
		slog.ErrorContext(ctx, "list failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	out := ListResponse{Photos: make([]PhotoView, 0, len(items))}
	for _, p := range items {
		url, err := h.Presigner.PresignGet(ctx, photos.ObjectKey(p.ID))
		if err != nil {
			slog.ErrorContext(ctx, "presign get failed", "id", p.ID, "err", err)
			return errorResponse(http.StatusInternalServerError, "internal error")
		}
		out.Photos = append(out.Photos, PhotoView{
			ID: p.ID, Lat: p.Lat, Lng: p.Lng, TakenAt: p.TakenAt, CreatedAt: p.CreatedAt, ImageURL: url,
		})
	}
	return jsonResponse(http.StatusOK, out)
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
