// Package photos holds the photo domain model, request validation, and the
// storage abstractions the Lambda handlers depend on.
package photos

import (
	"errors"
	"fmt"
	"time"
)

// Status values for a photo record.
const (
	StatusPending = "pending"
	StatusReady   = "ready"
)

// KeyPrefix is the S3 key prefix under which photo objects are stored.
const KeyPrefix = "photos/"

// MaxUploadBytes is the largest photo accepted by the presigned POST policy.
const MaxUploadBytes = 15 << 20 // 15 MiB

// AllowedContentTypes are the image types clients may upload.
var AllowedContentTypes = map[string]bool{
	"image/jpeg": true,
	"image/heic": true,
}

// Photo is the metadata record stored in DynamoDB.
type Photo struct {
	ID          string     `dynamodbav:"id"`
	Lat         float64    `dynamodbav:"lat"`
	Lng         float64    `dynamodbav:"lng"`
	TakenAt     *time.Time `dynamodbav:"takenAt,omitempty"`
	ContentType string     `dynamodbav:"contentType"`
	Status      string     `dynamodbav:"status"`
	Size        int64      `dynamodbav:"size,omitempty"`
	CreatedAt   time.Time  `dynamodbav:"createdAt"`
}

// ObjectKey returns the S3 key for a photo id.
func ObjectKey(id string) string { return KeyPrefix + id }

// CreateRequest is the body of POST /photos.
type CreateRequest struct {
	Lat         *float64 `json:"lat"`
	Lng         *float64 `json:"lng"`
	TakenAt     string   `json:"takenAt,omitempty"`
	ContentType string   `json:"contentType"`
}

// ErrValidation wraps all request validation failures.
var ErrValidation = errors.New("validation failed")

// Validate checks a create request and returns the parsed takenAt (nil when
// absent). Errors wrap ErrValidation.
func (r CreateRequest) Validate() (*time.Time, error) {
	invalid := func(format string, a ...any) error {
		return fmt.Errorf("%w: %s", ErrValidation, fmt.Sprintf(format, a...))
	}
	if r.Lat == nil {
		return nil, invalid("lat is required")
	}
	if r.Lng == nil {
		return nil, invalid("lng is required")
	}
	if *r.Lat < -90 || *r.Lat > 90 {
		return nil, invalid("lat must be between -90 and 90")
	}
	if *r.Lng < -180 || *r.Lng > 180 {
		return nil, invalid("lng must be between -180 and 180")
	}
	if !AllowedContentTypes[r.ContentType] {
		return nil, invalid("contentType must be image/jpeg or image/heic")
	}
	if r.TakenAt == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, r.TakenAt)
	if err != nil {
		return nil, invalid("takenAt must be an RFC3339 timestamp")
	}
	return &t, nil
}
