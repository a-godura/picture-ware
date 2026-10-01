package killswitch

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/service/apigatewayv2"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
)

type fakeAPI struct {
	in  *apigatewayv2.UpdateStageInput
	err error
}

func (f *fakeAPI) UpdateStage(_ context.Context, in *apigatewayv2.UpdateStageInput, _ ...func(*apigatewayv2.Options)) (*apigatewayv2.UpdateStageOutput, error) {
	f.in = in
	return &apigatewayv2.UpdateStageOutput{}, f.err
}

type fakeLambda struct {
	zeroed []string
	err    error
}

func (f *fakeLambda) PutFunctionConcurrency(_ context.Context, in *lambda.PutFunctionConcurrencyInput, _ ...func(*lambda.Options)) (*lambda.PutFunctionConcurrencyOutput, error) {
	if *in.ReservedConcurrentExecutions == 0 {
		f.zeroed = append(f.zeroed, *in.FunctionName)
	}
	return &lambda.PutFunctionConcurrencyOutput{}, f.err
}

func TestHandle(t *testing.T) {
	tests := []struct {
		name      string
		apiErr    error
		lambdaErr error
		wantErr   bool
	}{
		{name: "all succeed"},
		{name: "stage fails, functions still zeroed", apiErr: errors.New("denied"), wantErr: true},
		{name: "lambda fails", lambdaErr: errors.New("denied"), wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			api, fn := &fakeAPI{err: tt.apiErr}, &fakeLambda{err: tt.lambdaErr}
			h := &Handler{API: api, Lambda: fn, ApiID: "api1", StageName: "$default", Functions: []string{"f1", "f2"}}
			err := h.Handle(context.Background(), events.SNSEvent{Records: []events.SNSEventRecord{{SNS: events.SNSEntity{Subject: "budget"}}}})
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			rs := api.in.DefaultRouteSettings
			if *api.in.ApiId != "api1" || *api.in.StageName != "$default" || *rs.ThrottlingBurstLimit != 0 || *rs.ThrottlingRateLimit != 0 {
				t.Fatalf("unexpected UpdateStage input %+v", api.in)
			}
			if len(fn.zeroed) != 2 || fn.zeroed[0] != "f1" || fn.zeroed[1] != "f2" {
				t.Fatalf("zeroed = %v", fn.zeroed)
			}
		})
	}
}
