// Command killswitch disables the API when the cost budget is exceeded.
package main

import (
	"context"
	"log"
	"os"
	"strings"

	awslambda "github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/apigatewayv2"
	"github.com/aws/aws-sdk-go-v2/service/lambda"

	"github.com/a-godura/picture-ware/backend/internal/killswitch"
)

func main() {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("load aws config: %v", err)
	}
	h := &killswitch.Handler{
		API:       apigatewayv2.NewFromConfig(cfg),
		Lambda:    lambda.NewFromConfig(cfg),
		ApiID:     mustEnv("API_ID"),
		StageName: mustEnv("STAGE_NAME"),
		Functions: strings.Split(mustEnv("FUNCTION_NAMES"), ","),
	}
	awslambda.Start(h.Handle)
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}
