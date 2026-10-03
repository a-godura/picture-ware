// Command processor marks photos ready when their S3 object is created:
// trips/<tripId>/<id> for trip photos, photos/<userId>/<id> for the legacy
// per-user API.
package main

import (
	"context"
	"errors"
	"log"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"

	legacyphotos "github.com/a-godura/picture-ware/backend/internal/legacy/photos"
	legacyprocessor "github.com/a-godura/picture-ware/backend/internal/legacy/processor"
	"github.com/a-godura/picture-ware/backend/internal/photos"
	"github.com/a-godura/picture-ware/backend/internal/processor"
)

func main() {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("load aws config: %v", err)
	}
	db := dynamodb.NewFromConfig(cfg)
	trips := &processor.Handler{Store: &photos.DynamoStore{Client: db, Table: mustEnv("TABLE_NAME")}}
	legacy := &legacyprocessor.Handler{Store: &legacyphotos.DynamoStore{Client: db, Table: mustEnv("LEGACY_TABLE_NAME")}}

	lambda.Start(func(ctx context.Context, ev events.S3Event) error {
		var tripEv, legacyEv events.S3Event
		for _, r := range ev.Records {
			if strings.HasPrefix(r.S3.Object.Key, legacyphotos.KeyPrefix) {
				legacyEv.Records = append(legacyEv.Records, r)
			} else {
				tripEv.Records = append(tripEv.Records, r)
			}
		}
		return errors.Join(trips.Handle(ctx, tripEv), legacy.Handle(ctx, legacyEv))
	})
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}
