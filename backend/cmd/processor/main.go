// Command processor marks photos ready when their S3 object is created.
package main

import (
	"context"
	"log"
	"os"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"

	"github.com/a-godura/picture-ware/backend/internal/photos"
	"github.com/a-godura/picture-ware/backend/internal/processor"
)

func main() {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("load aws config: %v", err)
	}
	table := os.Getenv("TABLE_NAME")
	if table == "" {
		log.Fatal("missing env TABLE_NAME")
	}
	h := &processor.Handler{Store: &photos.DynamoStore{Client: dynamodb.NewFromConfig(cfg), Table: table}}
	lambda.Start(h.Handle)
}
