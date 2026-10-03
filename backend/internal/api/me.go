package api

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

// ProfileView is the body of GET and PATCH /me.
type ProfileView struct {
	UserID      string  `json:"userId"`
	DisplayName *string `json:"displayName"`
}

func (h *Handler) getMe(ctx context.Context, userID string) events.APIGatewayV2HTTPResponse {
	p, err := h.Store.GetProfile(ctx, userID)
	if err != nil {
		slog.ErrorContext(ctx, "get profile failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	return jsonResponse(http.StatusOK, ProfileView{UserID: userID, DisplayName: optional(p.DisplayName)})
}

func (h *Handler) updateMe(ctx context.Context, userID string, req events.APIGatewayV2HTTPRequest) events.APIGatewayV2HTTPResponse {
	var in photos.UpdateProfileRequest
	if resp, ok := decodeBody(req, &in, `body must be a JSON object like {"displayName": "Ana"}`); !ok {
		return resp
	}
	name, err := in.Validate()
	if err != nil {
		return errorResponse(http.StatusBadRequest, err.Error())
	}
	if err := h.Store.PutProfile(ctx, photos.Profile{UserID: userID, DisplayName: name}); err != nil {
		slog.ErrorContext(ctx, "put profile failed", "err", err)
		return errorResponse(http.StatusInternalServerError, "internal error")
	}
	return jsonResponse(http.StatusOK, ProfileView{UserID: userID, DisplayName: &name})
}
