package api

import (
	"context"
	"testing"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/contracttest"
)

// handleT calls Handle and checks the response against api/openapi.yaml: the
// legacy /photos routes are still part of the contract.
func (h *Handler) handleT(t *testing.T, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	t.Helper()
	resp, err := h.Handle(context.Background(), req)
	if err == nil {
		contracttest.Check(t, req, resp)
	}
	return resp, err
}
