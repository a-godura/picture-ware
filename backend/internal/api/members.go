package api

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"sort"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

// Roles in MemberView.
const (
	RoleOwner  = "owner"
	RoleMember = "member"
)

// MemberView is one entry of GET /trips/{tripId}/members.
type MemberView struct {
	UserID   string    `json:"userId"`
	Name     *string   `json:"name"`
	Role     string    `json:"role"`
	JoinedAt time.Time `json:"joinedAt"`
}

// MemberList is the 200 body of GET /trips/{tripId}/members.
type MemberList struct {
	Members []MemberView `json:"members"`
}

// InviteView is a trip's invite link.
type InviteView struct {
	Code      string    `json:"code"`
	URL       string    `json:"url"`
	AppURL    string    `json:"appUrl"`
	TripID    string    `json:"tripId"`
	CreatedBy string    `json:"createdBy"`
	CreatedAt time.Time `json:"createdAt"`
}

// TripSummary is what an invite reveals about a trip before joining.
type TripSummary struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	StartDate string  `json:"startDate"`
	EndDate   *string `json:"endDate"`
}

// InvitePreview is the 200 body of GET /invites/{code}.
type InvitePreview struct {
	Code          string      `json:"code"`
	Trip          TripSummary `json:"trip"`
	OwnerName     *string     `json:"ownerName"`
	MemberCount   int         `json:"memberCount"`
	AlreadyMember bool        `json:"alreadyMember"`
}

// AppScheme is the custom URL scheme the iOS app registers.
const AppScheme = "picture-ware"

// displayName looks up userID's display name, best effort: members are
// still added when the lookup fails, just without a name.
func (h *Handler) displayName(ctx context.Context, userID string) string {
	if h.Directory == nil {
		return ""
	}
	name, err := h.Directory.DisplayName(ctx, userID)
	if err != nil {
		slog.WarnContext(ctx, "display name lookup failed", "userId", userID, "err", err)
		return ""
	}
	return name
}

func (h *Handler) listMembers(ctx context.Context, tripID string) events.APIGatewayV2HTTPResponse {
	t, ok, resp := h.trip(ctx, tripID)
	if !ok {
		return resp
	}
	members, err := h.Store.ListMembers(ctx, tripID)
	if err != nil {
		slog.ErrorContext(ctx, "list members failed", "tripId", tripID, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	out := MemberList{Members: make([]MemberView, 0, len(members))}
	for _, m := range members {
		v := MemberView{UserID: m.UserID, Name: optional(m.Name), Role: RoleMember, JoinedAt: m.JoinedAt}
		if m.UserID == t.CreatedBy {
			v.Role = RoleOwner
			if v.JoinedAt.IsZero() {
				v.JoinedAt = t.CreatedAt
			}
		}
		out.Members = append(out.Members, v)
	}
	// The owner first, then in the order people joined.
	sort.SliceStable(out.Members, func(i, j int) bool {
		a, b := out.Members[i], out.Members[j]
		if (a.Role == RoleOwner) != (b.Role == RoleOwner) {
			return a.Role == RoleOwner
		}
		return a.JoinedAt.Before(b.JoinedAt)
	})
	return jsonResponse(http.StatusOK, out)
}

// removeMember: your own id means leave; removing someone else is for the
// owner only, and also rotates the invite so they can't rejoin with it; the
// owner can't leave.
func (h *Handler) removeMember(ctx context.Context, tripID, callerID, targetID string) events.APIGatewayV2HTTPResponse {
	if !photos.ValidID(targetID) {
		return errorResponse(http.StatusNotFound, "member not found")
	}
	for range 3 {
		t, ok, resp := h.trip(ctx, tripID)
		if !ok {
			return resp
		}
		if targetID != callerID && callerID != t.CreatedBy {
			return errorResponse(http.StatusForbidden, "only the trip's creator can remove members")
		}
		if targetID == t.CreatedBy {
			return errorResponse(http.StatusConflict, "the trip's creator can't leave it")
		}
		var rotate *photos.Rotation
		if targetID != callerID && t.InviteCode != "" {
			code, err := h.NewCode()
			if err != nil {
				slog.ErrorContext(ctx, "new invite code failed", "err", err)
				return errorResponse(http.StatusInternalServerError, "internal error")
			}
			rotate = &photos.Rotation{
				New:      photos.Invite{Code: code, TripID: tripID, CreatedBy: callerID, CreatedAt: h.Now().UTC()},
				Previous: t.InviteCode,
			}
		}
		err := h.Store.RemoveMember(ctx, tripID, targetID, rotate)
		switch {
		case err == nil:
			return events.APIGatewayV2HTTPResponse{StatusCode: http.StatusNoContent}
		case errors.Is(err, photos.ErrConflict):
			continue // the invite changed meanwhile: re-read and rotate that one
		case errors.Is(err, photos.ErrNotFound):
			return errorResponse(http.StatusNotFound, "member not found")
		}
		slog.ErrorContext(ctx, "remove member failed", "tripId", tripID, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	slog.ErrorContext(ctx, "invite kept changing", "tripId", tripID)
	return errorResponse(http.StatusInternalServerError, "internal error")
}

// tripInvite returns the trip's active invite, creating it on first use.
func (h *Handler) tripInvite(ctx context.Context, tripID, userID string, req events.APIGatewayV2HTTPRequest) events.APIGatewayV2HTTPResponse {
	for range 3 {
		t, ok, resp := h.trip(ctx, tripID)
		if !ok {
			return resp
		}
		if t.InviteCode != "" {
			inv, err := h.Store.GetInvite(ctx, t.InviteCode)
			if err == nil {
				return jsonResponse(http.StatusOK, inviteView(req, inv))
			}
			if !errors.Is(err, photos.ErrNotFound) {
				slog.ErrorContext(ctx, "get invite failed", "tripId", tripID, "err", err)
				return errorResponse(http.StatusInternalServerError, "internal error")
			}
			// The trip points at a missing invite: replace it below.
		}
		inv, err := h.newInvite(ctx, tripID, userID, t.InviteCode)
		if errors.Is(err, photos.ErrConflict) {
			continue // someone else created or rotated it just now: return theirs
		}
		if err != nil {
			return h.inviteError(ctx, tripID, err)
		}
		return jsonResponse(http.StatusOK, inviteView(req, inv))
	}
	slog.ErrorContext(ctx, "invite kept changing", "tripId", tripID)
	return errorResponse(http.StatusInternalServerError, "internal error")
}

func (h *Handler) rotateInvite(ctx context.Context, tripID, userID string, req events.APIGatewayV2HTTPRequest) events.APIGatewayV2HTTPResponse {
	for range 3 {
		t, ok, resp := h.trip(ctx, tripID)
		if !ok {
			return resp
		}
		if userID != t.CreatedBy {
			return errorResponse(http.StatusForbidden, "only the trip's creator can reset the invite link")
		}
		inv, err := h.newInvite(ctx, tripID, userID, t.InviteCode)
		if errors.Is(err, photos.ErrConflict) {
			continue
		}
		if err != nil {
			return h.inviteError(ctx, tripID, err)
		}
		return jsonResponse(http.StatusCreated, inviteView(req, inv))
	}
	slog.ErrorContext(ctx, "invite kept changing", "tripId", tripID)
	return errorResponse(http.StatusInternalServerError, "internal error")
}

func (h *Handler) newInvite(ctx context.Context, tripID, userID, previous string) (photos.Invite, error) {
	code, err := h.NewCode()
	if err != nil {
		return photos.Invite{}, err
	}
	inv := photos.Invite{Code: code, TripID: tripID, CreatedBy: userID, CreatedAt: h.Now().UTC()}
	return inv, h.Store.PutInvite(ctx, inv, previous)
}

func (h *Handler) inviteError(ctx context.Context, tripID string, err error) events.APIGatewayV2HTTPResponse {
	if errors.Is(err, photos.ErrNotFound) {
		return errorResponse(http.StatusNotFound, "trip not found")
	}
	slog.ErrorContext(ctx, "create invite failed", "tripId", tripID, "err", err)
	return errorResponse(http.StatusInternalServerError, "internal error")
}

// invite resolves a code to its invite and trip. Malformed, unknown and
// rotated codes are all "invite not found".
func (h *Handler) invite(ctx context.Context, code string) (photos.Invite, photos.Trip, events.APIGatewayV2HTTPResponse, bool) {
	notFound := errorResponse(http.StatusNotFound, "invite not found")
	if !photos.ValidInviteCode(code) {
		return photos.Invite{}, photos.Trip{}, notFound, false
	}
	inv, err := h.Store.GetInvite(ctx, code)
	if errors.Is(err, photos.ErrNotFound) {
		return inv, photos.Trip{}, notFound, false
	}
	if err != nil {
		slog.ErrorContext(ctx, "get invite failed", "err", err)
		return inv, photos.Trip{}, errorResponse(http.StatusInternalServerError, "internal error"), false
	}
	t, err := h.Store.GetTrip(ctx, inv.TripID)
	if errors.Is(err, photos.ErrNotFound) || err == nil && t.InviteCode != code {
		return inv, t, notFound, false
	}
	if err != nil {
		slog.ErrorContext(ctx, "get trip failed", "tripId", inv.TripID, "err", err)
		return inv, t, errorResponse(http.StatusInternalServerError, "internal error"), false
	}
	return inv, t, events.APIGatewayV2HTTPResponse{}, true
}

func (h *Handler) previewInvite(ctx context.Context, userID, code string) events.APIGatewayV2HTTPResponse {
	_, t, resp, ok := h.invite(ctx, code)
	if !ok {
		return resp
	}
	member, err := h.Store.IsMember(ctx, t.ID, userID)
	if err != nil {
		slog.ErrorContext(ctx, "membership check failed", "tripId", t.ID, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	var ownerName *string
	owner, err := h.Store.GetMember(ctx, t.ID, t.CreatedBy)
	switch {
	case err == nil:
		ownerName = optional(owner.Name)
	case !errors.Is(err, photos.ErrNotFound):
		slog.ErrorContext(ctx, "get owner failed", "tripId", t.ID, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	v := tripView(t)
	return jsonResponse(http.StatusOK, InvitePreview{
		Code:          code,
		Trip:          TripSummary{ID: v.ID, Name: v.Name, StartDate: v.StartDate, EndDate: v.EndDate},
		OwnerName:     ownerName,
		MemberCount:   t.Members(),
		AlreadyMember: member,
	})
}

func (h *Handler) acceptInvite(ctx context.Context, userID, code string) events.APIGatewayV2HTTPResponse {
	_, t, resp, ok := h.invite(ctx, code)
	if !ok {
		return resp
	}
	member, err := h.Store.IsMember(ctx, t.ID, userID)
	if err != nil {
		slog.ErrorContext(ctx, "membership check failed", "tripId", t.ID, "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	if member {
		return jsonResponse(http.StatusOK, tripView(t))
	}
	m := photos.Member{UserID: userID, Name: h.displayName(ctx, userID), JoinedAt: h.Now().UTC()}
	err = h.Store.AddMember(ctx, t, m, code)
	switch {
	case err == nil, errors.Is(err, photos.ErrAlreadyMember):
		return jsonResponse(http.StatusOK, tripView(t))
	case errors.Is(err, photos.ErrNotFound):
		return errorResponse(http.StatusNotFound, "invite not found")
	case errors.Is(err, photos.ErrTripFull):
		return errorResponse(http.StatusConflict, "trip is full")
	}
	slog.ErrorContext(ctx, "add member failed", "tripId", t.ID, "err", err)
	return errorResponse(http.StatusInternalServerError, "internal error")
}

// trip loads a trip the caller is already known to be a member of.
func (h *Handler) trip(ctx context.Context, tripID string) (photos.Trip, bool, events.APIGatewayV2HTTPResponse) {
	t, err := h.Store.GetTrip(ctx, tripID)
	if errors.Is(err, photos.ErrNotFound) {
		return t, false, errorResponse(http.StatusNotFound, "trip not found")
	}
	if err != nil {
		slog.ErrorContext(ctx, "get trip failed", "tripId", tripID, "err", err)
		return t, false, errorResponse(http.StatusInternalServerError, "internal error")
	}
	return t, true, events.APIGatewayV2HTTPResponse{}
}

func inviteView(req events.APIGatewayV2HTTPRequest, inv photos.Invite) InviteView {
	return InviteView{
		Code:      inv.Code,
		URL:       "https://" + req.RequestContext.DomainName + "/j/" + inv.Code,
		AppURL:    AppScheme + "://join/" + inv.Code,
		TripID:    inv.TripID,
		CreatedBy: inv.CreatedBy,
		CreatedAt: inv.CreatedAt,
	}
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
