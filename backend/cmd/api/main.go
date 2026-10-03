// Command api is the HTTP API Lambda: /trips, plus the legacy /photos routes
// until no client uses them.
package main

import (
	"context"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"

	"github.com/a-godura/picture-ware/backend/internal/api"
	legacyapi "github.com/a-godura/picture-ware/backend/internal/legacy/api"
	legacyphotos "github.com/a-godura/picture-ware/backend/internal/legacy/photos"
	"github.com/a-godura/picture-ware/backend/internal/photos"
)

func main() {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("load aws config: %v", err)
	}
	db := dynamodb.NewFromConfig(cfg)
	s3Client := s3.NewFromConfig(cfg)
	presign := s3.NewPresignClient(s3Client)
	bucket := mustEnv("BUCKET_NAME")

	trips := &api.Handler{
		Store:   &photos.DynamoStore{Client: db, Table: mustEnv("TABLE_NAME")},
		Objects: &photos.S3Objects{Client: s3Client, Bucket: bucket},
		Presigner: &photos.S3Presigner{
			Client: presign, Bucket: bucket, PostExpiry: 10 * time.Minute, GetExpiry: time.Hour,
		},
		NewID: uuid.NewString,
		Now:   time.Now,
		Limits: photos.Limits{
			DailyUploads: mustInt("QUOTA_DAILY_UPLOADS"),
			UserBytes:    mustInt("QUOTA_USER_BYTES"),
			TotalBytes:   mustInt("QUOTA_TOTAL_BYTES"),
		},
	}
	legacy := &legacyapi.Handler{
		Store:   &legacyphotos.DynamoStore{Client: db, Table: mustEnv("LEGACY_TABLE_NAME")},
		Objects: &legacyphotos.S3Objects{Client: s3Client, Bucket: bucket},
		Presigner: &legacyphotos.S3Presigner{
			Client: presign, Bucket: bucket, PostExpiry: 10 * time.Minute, GetExpiry: time.Hour,
		},
		NewID: uuid.NewString,
		Now:   time.Now,
	}

	lambda.Start(func(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
		if isLegacyRoute(req.RouteKey) {
			return legacy.Handle(ctx, req)
		}
		return trips.Handle(ctx, req)
	})
}

// isLegacyRoute reports whether a route key ("METHOD /path") is one of the
// pre-trips /photos routes.
func isLegacyRoute(routeKey string) bool {
	_, path, _ := strings.Cut(routeKey, " ")
	return path == "/photos" || strings.HasPrefix(path, "/photos/")
}

func mustInt(k string) int64 {
	n, err := strconv.ParseInt(mustEnv(k), 10, 64)
	if err != nil || n < 0 {
		log.Fatalf("env %s must be a non-negative integer", k)
	}
	return n
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}
