package photos

import (
	"crypto/rand"
	"encoding/base32"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// MaxMembers is the most people one trip can have.
const MaxMembers = 50

// Member is one person in a trip. JoinedAt is zero for trips created before
// members were recorded with it. Names aren't stored here: they're the
// members' profiles' display names, resolved when read.
type Member struct {
	UserID   string    `dynamodbav:"userId"`
	JoinedAt time.Time `dynamodbav:"joinedAt"`
}

// Profile is a user's own settings. DisplayName is what other members see
// ("" until the user chooses one); emails are never shown.
type Profile struct {
	UserID      string `dynamodbav:"userId"`
	DisplayName string `dynamodbav:"displayName,omitempty"`
}

const maxDisplayNameLen = 50

// UpdateProfileRequest is the body of PATCH /me.
type UpdateProfileRequest struct {
	DisplayName *string `json:"displayName"`
}

// Validate returns the trimmed display name. Errors wrap ErrValidation.
func (r UpdateProfileRequest) Validate() (string, error) {
	if r.DisplayName == nil {
		return "", fmt.Errorf("%w: displayName is required", ErrValidation)
	}
	name := strings.TrimSpace(*r.DisplayName)
	switch {
	case name == "":
		return "", fmt.Errorf("%w: displayName is required", ErrValidation)
	case utf8.RuneCountInString(name) > maxDisplayNameLen:
		return "", fmt.Errorf("%w: displayName must be at most %d characters", ErrValidation, maxDisplayNameLen)
	case strings.IndexFunc(name, unicode.IsControl) >= 0:
		return "", fmt.Errorf("%w: displayName must not contain control characters", ErrValidation)
	}
	return name, nil
}

// Invite lets anyone signed in who has Code join TripID. A trip has at most
// one active invite (its META item's inviteCode).
type Invite struct {
	Code      string    `dynamodbav:"code"`
	TripID    string    `dynamodbav:"tripId"`
	CreatedBy string    `dynamodbav:"createdBy"`
	CreatedAt time.Time `dynamodbav:"createdAt"`
}

var (
	// ErrAlreadyMember: the user is already in the trip.
	ErrAlreadyMember = errors.New("already a member")
	// ErrTripFull: the trip has MaxMembers members.
	ErrTripFull = errors.New("trip is full")
	// ErrConflict: the record changed concurrently; re-read and retry.
	ErrConflict = errors.New("conflict")
)

// inviteEncoding is lowercase RFC 4648 base32 without padding: codes are
// easy to read aloud and safe in URLs and HTML.
var inviteEncoding = base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)

const inviteCodeLen = 26 // 16 random bytes

// NewInviteCode returns a fresh 128-bit random invite code.
func NewInviteCode() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("random invite code: %w", err)
	}
	return inviteEncoding.EncodeToString(b), nil
}

// ValidInviteCode reports whether s has the shape of an invite code. It
// says nothing about whether the code exists.
func ValidInviteCode(s string) bool {
	if len(s) != inviteCodeLen {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '2' && c <= '7') {
			return false
		}
	}
	return true
}
