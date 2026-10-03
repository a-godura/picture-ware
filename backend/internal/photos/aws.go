package photos

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// S3Objects deletes photo objects. S3 deletes are idempotent: deleting a
// missing key succeeds.
type S3Objects struct {
	Client *s3.Client
	Bucket string
}

// Delete removes the object at key.
func (o *S3Objects) Delete(ctx context.Context, key string) error {
	if _, err := o.Client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &o.Bucket, Key: &key}); err != nil {
		return fmt.Errorf("delete object: %w", err)
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
