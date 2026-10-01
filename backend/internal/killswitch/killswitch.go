// Package killswitch shuts the API down when the cost budget is exceeded:
// it throttles the HTTP API stage to zero and pins Lambda concurrency to zero.
package killswitch

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/apigatewayv2"
	apitypes "github.com/aws/aws-sdk-go-v2/service/apigatewayv2/types"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
)

// StageUpdater is the subset of the API Gateway v2 client used.
type StageUpdater interface {
	UpdateStage(ctx context.Context, in *apigatewayv2.UpdateStageInput, opts ...func(*apigatewayv2.Options)) (*apigatewayv2.UpdateStageOutput, error)
}

// ConcurrencyPutter is the subset of the Lambda client used.
type ConcurrencyPutter interface {
	PutFunctionConcurrency(ctx context.Context, in *lambda.PutFunctionConcurrencyInput, opts ...func(*lambda.Options)) (*lambda.PutFunctionConcurrencyOutput, error)
}

// Handler applies the kill switch.
type Handler struct {
	API       StageUpdater
	Lambda    ConcurrencyPutter
	ApiID     string
	StageName string
	Functions []string
}

// Handle is invoked by the budget's SNS topic. Every step is attempted even
// if an earlier one fails; all errors are returned together.
func (h *Handler) Handle(ctx context.Context, ev events.SNSEvent) error {
	for _, r := range ev.Records {
		slog.WarnContext(ctx, "kill switch triggered", "subject", r.SNS.Subject, "message", r.SNS.Message)
	}
	var errs []error
	_, err := h.API.UpdateStage(ctx, &apigatewayv2.UpdateStageInput{
		ApiId:     aws.String(h.ApiID),
		StageName: aws.String(h.StageName),
		DefaultRouteSettings: &apitypes.RouteSettings{
			ThrottlingBurstLimit: aws.Int32(0),
			ThrottlingRateLimit:  aws.Float64(0),
		},
	})
	if err != nil {
		errs = append(errs, fmt.Errorf("throttle stage: %w", err))
	}
	for _, fn := range h.Functions {
		_, err := h.Lambda.PutFunctionConcurrency(ctx, &lambda.PutFunctionConcurrencyInput{
			FunctionName:                 aws.String(fn),
			ReservedConcurrentExecutions: aws.Int32(0),
		})
		if err != nil {
			errs = append(errs, fmt.Errorf("zero concurrency for %s: %w", fn, err))
		}
	}
	if err := errors.Join(errs...); err != nil {
		return err
	}
	slog.WarnContext(ctx, "kill switch applied", "api", h.ApiID, "functions", h.Functions)
	return nil
}
