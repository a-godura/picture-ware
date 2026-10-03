// Package photos holds the trip and photo domain model, request validation,
// and the storage abstractions the Lambda handlers depend on.
package photos

import (
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

// Status values for a photo record.
const (
	StatusPending = "pending"
	StatusReady   = "ready"
)

// KeyPrefix is the S3 key prefix under which trip photo objects are stored.
// Each object lives at trips/<tripId>/<id>. (photos/ belongs to the legacy
// per-user API.)
const KeyPrefix = "trips/"

// MaxUploadBytes is the largest photo accepted by the presigned POST policy.
const MaxUploadBytes = 15 << 20 // 15 MiB

// AllowedContentTypes are the image types clients may upload.
var AllowedContentTypes = map[string]bool{
	"image/jpeg": true,
	"image/heic": true,
}

// Trip groups photos from a vacation or event. Dates are calendar days
// (YYYY-MM-DD); EndDate is optional.
type Trip struct {
	ID        string    `dynamodbav:"tripId"`
	Name      string    `dynamodbav:"name"`
	StartDate string    `dynamodbav:"startDate"`
	EndDate   string    `dynamodbav:"endDate,omitempty"`
	CreatedBy string    `dynamodbav:"createdBy"`
	CreatedAt time.Time `dynamodbav:"createdAt"`

	// Only on the trip's own record (not the "my trips" copies): the active
	// invite code ("" if none yet) and the number of members (0 means 1, for
	// trips created before it was counted).
	InviteCode  string `dynamodbav:"inviteCode,omitempty"`
	MemberCount int    `dynamodbav:"memberCount,omitempty"`
}

// Members returns the trip's member count.
func (t Trip) Members() int { return max(t.MemberCount, 1) }

// summary drops the fields that only belong on the trip's own record.
func (t Trip) summary() Trip {
	t.InviteCode, t.MemberCount = "", 0
	return t
}

// Photo is the metadata record for one photo in a trip.
type Photo struct {
	TripID      string     `dynamodbav:"tripId"`
	ID          string     `dynamodbav:"id"`
	UploaderID  string     `dynamodbav:"uploaderId"`
	Lat         float64    `dynamodbav:"lat"`
	Lng         float64    `dynamodbav:"lng"`
	TakenAt     *time.Time `dynamodbav:"takenAt,omitempty"`
	ContentType string     `dynamodbav:"contentType"`
	Status      string     `dynamodbav:"status"`
	Size        int64      `dynamodbav:"size,omitempty"`
	CreatedAt   time.Time  `dynamodbav:"createdAt"`
}

// ObjectKey returns the S3 key for a trip's photo: trips/<tripID>/<id>.
func ObjectKey(tripID, id string) string { return KeyPrefix + tripID + "/" + id }

// ParseObjectKey is the inverse of ObjectKey. It rejects keys outside
// KeyPrefix and keys that are not exactly <tripID>/<id> after it.
func ParseObjectKey(key string) (tripID, id string, ok bool) {
	rest, ok := strings.CutPrefix(key, KeyPrefix)
	if !ok {
		return "", "", false
	}
	tripID, id, ok = strings.Cut(rest, "/")
	if !ok || !ValidID(tripID) || !ValidID(id) {
		return "", "", false
	}
	return tripID, id, true
}

// ValidID reports whether s is safe to use as a key segment. Trip and photo
// ids are server-generated UUIDs and Cognito "sub" values are UUIDs; this
// accepts a conservative superset.
func ValidID(s string) bool {
	if s == "" || len(s) > 128 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// CreateTripRequest is the body of POST /trips.
type CreateTripRequest struct {
	Name      string `json:"name"`
	StartDate string `json:"startDate"`
	EndDate   string `json:"endDate,omitempty"`
}

const (
	dateLayout     = "2006-01-02"
	maxTripNameLen = 100
)

// Validate checks a create-trip request and returns it with the name trimmed.
// Errors wrap ErrValidation.
func (r CreateTripRequest) Validate() (CreateTripRequest, error) {
	r.Name = strings.TrimSpace(r.Name)
	switch {
	case r.Name == "":
		return r, fmt.Errorf("%w: name is required", ErrValidation)
	case utf8.RuneCountInString(r.Name) > maxTripNameLen:
		return r, fmt.Errorf("%w: name must be at most %d characters", ErrValidation, maxTripNameLen)
	}
	start, err := time.Parse(dateLayout, r.StartDate)
	if err != nil {
		return r, fmt.Errorf("%w: startDate must be a date like 2026-10-03", ErrValidation)
	}
	if r.EndDate == "" {
		return r, nil
	}
	end, err := time.Parse(dateLayout, r.EndDate)
	if err != nil {
		return r, fmt.Errorf("%w: endDate must be a date like 2026-10-03", ErrValidation)
	}
	if end.Before(start) {
		return r, fmt.Errorf("%w: endDate must not be before startDate", ErrValidation)
	}
	return r, nil
}

// CreateRequest is the body of POST /trips/{tripId}/photos.
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
