// Command api is the HTTP API Lambda for /photos.
package main

import (
	"context"
	"log"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"

	"github.com/a-godura/picture-ware/backend/internal/api"
	"github.com/a-godura/picture-ware/backend/internal/photos"
)

func main() {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("load aws config: %v", err)
	}
	h := &api.Handler{
		Store: &photos.DynamoStore{Client: dynamodb.NewFromConfig(cfg), Table: mustEnv("TABLE_NAME")},
		Presigner: &photos.S3Presigner{
			Client:     s3.NewPresignClient(s3.NewFromConfig(cfg)),
			Bucket:     mustEnv("BUCKET_NAME"),
			PostExpiry: 10 * time.Minute,
			GetExpiry:  time.Hour,
		},
		NewID: uuid.NewString,
		Now:   time.Now,
	}
	lambda.Start(h.Handle)
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}
