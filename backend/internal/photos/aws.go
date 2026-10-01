package photos

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// ErrNotFound is returned when a photo record does not exist.
var ErrNotFound = errors.New("photo not found")

// DynamoStore persists photo metadata in a DynamoDB table keyed by "id".
type DynamoStore struct {
	Client *dynamodb.Client
	Table  string
}

// Put creates a new photo record. It fails if the id already exists.
func (s *DynamoStore) Put(ctx context.Context, p Photo) error {
	item, err := attributevalue.MarshalMap(p)
	if err != nil {
		return fmt.Errorf("marshal photo: %w", err)
	}
	_, err = s.Client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName:           &s.Table,
		Item:                item,
		ConditionExpression: aws.String("attribute_not_exists(id)"),
	})
	if err != nil {
		return fmt.Errorf("put photo: %w", err)
	}
	return nil
}

// ListReady returns every photo whose status is "ready". It uses a Scan,
// which is fine at v1 scale.
func (s *DynamoStore) ListReady(ctx context.Context) ([]Photo, error) {
	in := &dynamodb.ScanInput{
		TableName:                 &s.Table,
		FilterExpression:          aws.String("#s = :ready"),
		ExpressionAttributeNames:  map[string]string{"#s": "status"},
		ExpressionAttributeValues: map[string]types.AttributeValue{":ready": &types.AttributeValueMemberS{Value: StatusReady}},
	}
	var out []Photo
	p := dynamodb.NewScanPaginator(s.Client, in)
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("scan photos: %w", err)
		}
		var batch []Photo
		if err := attributevalue.UnmarshalListOfMaps(page.Items, &batch); err != nil {
			return nil, fmt.Errorf("unmarshal photos: %w", err)
		}
		out = append(out, batch...)
	}
	return out, nil
}

// MarkReady flips an existing record to "ready" and records the object size.
// It returns ErrNotFound if no record exists for id.
func (s *DynamoStore) MarkReady(ctx context.Context, id string, size int64) error {
	_, err := s.Client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:                &s.Table,
		Key:                      map[string]types.AttributeValue{"id": &types.AttributeValueMemberS{Value: id}},
		UpdateExpression:         aws.String("SET #s = :ready, #sz = :size"),
		ConditionExpression:      aws.String("attribute_exists(id)"),
		ExpressionAttributeNames: map[string]string{"#s": "status", "#sz": "size"},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":ready": &types.AttributeValueMemberS{Value: StatusReady},
			":size":  &types.AttributeValueMemberN{Value: strconv.FormatInt(size, 10)},
		},
	})
	var ccf *types.ConditionalCheckFailedException
	if errors.As(err, &ccf) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("mark ready: %w", err)
	}
	return nil
}

// Upload is a presigned S3 POST: the client sends multipart/form-data to URL
// with Fields first and the file (field name "file") last.
type Upload struct {
	URL    string            `json:"url"`
	Fields map[string]string `json:"fields"`
}

// S3Presigner creates presigned upload (POST) and download (GET) requests.
type S3Presigner struct {
	Client     *s3.PresignClient
	Bucket     string
	PostExpiry time.Duration
	GetExpiry  time.Duration
}

// PresignUpload returns a presigned POST restricted to exactly key, exactly
// contentType, and 1..MaxUploadBytes bytes.
func (p *S3Presigner) PresignUpload(ctx context.Context, key, contentType string) (Upload, error) {
	req, err := p.Client.PresignPostObject(ctx, &s3.PutObjectInput{
		Bucket: &p.Bucket,
		Key:    &key,
	}, func(o *s3.PresignPostOptions) {
		o.Expires = p.PostExpiry
		o.Conditions = []any{
			map[string]string{"key": key},
			map[string]string{"Content-Type": contentType},
			[]any{"content-length-range", 1, MaxUploadBytes},
		}
	})
	if err != nil {
		return Upload{}, fmt.Errorf("presign post: %w", err)
	}
	fields := make(map[string]string, len(req.Values)+1)
	for k, v := range req.Values {
		fields[k] = v
	}
	fields["Content-Type"] = contentType
	return Upload{URL: req.URL, Fields: fields}, nil
}

// PresignGet returns a time-limited download URL for key.
func (p *S3Presigner) PresignGet(ctx context.Context, key string) (string, error) {
	req, err := p.Client.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: &p.Bucket,
		Key:    &key,
	}, s3.WithPresignExpires(p.GetExpiry))
	if err != nil {
		return "", fmt.Errorf("presign get: %w", err)
	}
	return req.URL, nil
}
