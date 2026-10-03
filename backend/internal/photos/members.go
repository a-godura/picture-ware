package photos

import (
	"crypto/rand"
	"encoding/base32"
	"errors"
	"fmt"
	"strings"
	"time"
)

// MaxMembers is the most people one trip can have.
const MaxMembers = 50

// Member is one person in a trip. Name is a display name captured when they
// joined ("" when unknown); JoinedAt is zero for trips created before
// members were recorded with it.
type Member struct {
	UserID   string    `dynamodbav:"userId"`
	Name     string    `dynamodbav:"name,omitempty"`
	JoinedAt time.Time `dynamodbav:"joinedAt"`
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

// DisplayName picks what other members see for a user: their name if set,
// otherwise the part of their email before the "@" (never the full email).
func DisplayName(name, email string) string {
	if n := strings.TrimSpace(name); n != "" {
		return n
	}
	local, _, ok := strings.Cut(email, "@")
	if !ok {
		return ""
	}
	return local
}
