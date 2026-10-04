// Command tripwire blocks photo downloads when the S3 download alarm fires.
package main

import (
	"context"
	"log"
	"os"
	"strings"

	awslambda "github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"github.com/a-godura/picture-ware/backend/internal/tripwire"
)

func main() {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("load aws config: %v", err)
	}
	h := &tripwire.Handler{
		S3:        s3.NewFromConfig(cfg),
		Bucket:    mustEnv("BUCKET_NAME"),
		BucketARN: mustEnv("BUCKET_ARN"),
		Prefixes:  strings.Split(mustEnv("PROTECTED_PREFIXES"), ","),
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
