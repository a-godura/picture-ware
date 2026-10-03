package photos

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestInviteCodes(t *testing.T) {
	seen := map[string]bool{}
	for range 1000 {
		c, err := NewInviteCode()
		if err != nil {
			t.Fatal(err)
		}
		if !ValidInviteCode(c) || seen[c] {
			t.Fatalf("bad or repeated code %q", c)
		}
		seen[c] = true
	}
	for _, bad := range []string{"", strings.Repeat("a", 25), strings.Repeat("a", 27), strings.Repeat("A", 26),
		strings.Repeat("a", 25) + "1", strings.Repeat("a", 25) + "8", strings.Repeat("a", 24) + "/x"} {
		if ValidInviteCode(bad) {
			t.Errorf("ValidInviteCode(%q) = true", bad)
		}
	}
}

func TestUpdateProfileValidate(t *testing.T) {
	ptr := func(s string) *string { return &s }
	for _, tt := range []struct {
		in      *string
		want    string
		wantErr string
	}{
		{ptr("  Ana Silva "), "Ana Silva", ""},
		{ptr(strings.Repeat("é", 50)), strings.Repeat("é", 50), ""},
		{ptr("Ben 🏔️"), "Ben 🏔️", ""},
		{nil, "", "required"},
		{ptr(" \t "), "", "required"},
		{ptr(strings.Repeat("é", 51)), "", "at most 50"},
		{ptr("a\u0000b"), "", "control"},
		{ptr("two\nlines"), "", "control"},
	} {
		got, err := UpdateProfileRequest{DisplayName: tt.in}.Validate()
		if tt.wantErr != "" {
			if err == nil || !errors.Is(err, ErrValidation) || !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("Validate(%v) err = %v, want %q", tt.in, err, tt.wantErr)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("Validate(%q) = %q, %v", *tt.in, got, err)
		}
	}
}

func TestDisplayNamesBatches(t *testing.T) {
	var ids []string
	for i := range 130 {
		ids = append(ids, fmt.Sprintf("user-%d", i))
	}
	// First call: names for user-0 and user-1, user-2 left unprocessed and
	// returned by the retry; user-3 has a profile without a name.
	store, f := newFakeStore(t, func(_ string, call int) (int, string) {
		switch call {
		case 0:
			return 200, `{"Responses":{"AppTable":[{"userId":{"S":"user-0"},"displayName":{"S":"Ana"}},` +
				`{"userId":{"S":"user-1"},"displayName":{"S":"Ben"}},{"userId":{"S":"user-3"}}]},` +
				`"UnprocessedKeys":{"AppTable":{"Keys":[{"PK":{"S":"USER#user-2"},"SK":{"S":"PROFILE"}}]}}}`
		case 1:
			return 200, `{"Responses":{"AppTable":[{"userId":{"S":"user-2"},"displayName":{"S":"Cy"}}]}}`
		}
		return 200, `{"Responses":{"AppTable":[]}}`
	})
	got, err := store.DisplayNames(context.Background(), ids)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got["user-0"] != "Ana" || got["user-1"] != "Ben" || got["user-2"] != "Cy" {
		t.Fatalf("names = %v", got)
	}
	if len(f.calls) != 3 { // 100 keys, the retry, then the remaining 30
		t.Fatalf("calls = %d", len(f.calls))
	}
	keys := f.calls[0].Body["RequestItems"].(map[string]any)["AppTable"].(map[string]any)["Keys"].([]any)
	if len(keys) != 100 || str(keys[0], "SK") != "PROFILE" || str(keys[0], "PK") != "USER#user-0" {
		t.Fatalf("first batch = %d keys, %v", len(keys), keys[0])
	}
}

func TestGetProfileMissing(t *testing.T) {
	store, _ := newFakeStore(t, func(string, int) (int, string) { return 200, `{}` })
	p, err := store.GetProfile(context.Background(), "user-9")
	if err != nil || p != (Profile{UserID: "user-9"}) {
		t.Fatalf("GetProfile = %+v, %v", p, err)
	}
}

// respondWith answers every DynamoDB call with one canned response.
func respondWith(status int, body string) func(string, int) (int, string) {
	return func(string, int) (int, string) { return status, body }
}

func canceled(reasons string) func(string, int) (int, string) {
	return respondWith(400, `{"__type":"com.amazonaws.dynamodb.v20120810#TransactionCanceledException",`+
		`"message":"Transaction cancelled","CancellationReasons":`+reasons+`}`)
}

// inviteTrip carries the fields that must not be copied into "my trips".
var inviteTrip = func() Trip { t := testTrip; t.InviteCode, t.MemberCount = "should-not-be-copied", 7; return t }()

func TestAddMemberErrors(t *testing.T) {
	m := Member{UserID: "user-2", JoinedAt: time.Unix(0, 0).UTC()}
	tests := []struct {
		name string
		fake func(string, int) (int, string)
		want error
	}{
		{"ok", nil, nil},
		{"already member", canceled(`[{"Code":"ConditionalCheckFailed"},{"Code":"None"},{"Code":"None"}]`), ErrAlreadyMember},
		{"rotated", canceled(`[{"Code":"None"},{"Code":"None"},{"Code":"ConditionalCheckFailed","Item":{"inviteCode":{"S":"newcode"},"memberCount":{"N":"3"}}}]`), ErrNotFound},
		{"full", canceled(`[{"Code":"None"},{"Code":"None"},{"Code":"ConditionalCheckFailed","Item":{"inviteCode":{"S":"code"},"memberCount":{"N":"50"}}}]`), ErrTripFull},
		{"trip gone", canceled(`[{"Code":"None"},{"Code":"None"},{"Code":"ConditionalCheckFailed"}]`), ErrNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store, _ := newFakeStore(t, tt.fake)
			err := store.AddMember(context.Background(), inviteTrip, m, "code")
			if !errors.Is(err, tt.want) || (tt.want == nil) != (err == nil) {
				t.Fatalf("err = %v, want %v", err, tt.want)
			}
		})
	}

	// The request: member + "my trips" copy (without the trip-only fields)
	// + a guarded count increment, in one transaction.
	store, f := newFakeStore(t, nil)
	if err := store.AddMember(context.Background(), inviteTrip, m, "code"); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(f.calls[0].Body)
	s := string(raw)
	for _, want := range []string{`"MEMBER#user-2"`, `"USER#user-2"`, `"TRIP#trip-1"`, `inviteCode = :code`, `memberCount \u003c :max`, `"N":"50"`} {
		if !strings.Contains(s, want) {
			t.Errorf("request lacks %s: %s", want, s)
		}
	}
	if strings.Contains(s, "should-not-be-copied") {
		t.Errorf("trip-only fields copied into the user's trip list: %s", s)
	}
}

func TestPutInviteAndRemoveMemberErrors(t *testing.T) {
	inv := Invite{Code: "new", TripID: "trip-1", CreatedBy: "owner", CreatedAt: time.Unix(0, 0).UTC()}
	conflict, _ := newFakeStore(t, canceled(`[{"Code":"None"},{"Code":"ConditionalCheckFailed","Item":{"inviteCode":{"S":"other"}}},{"Code":"None"}]`))
	if err := conflict.PutInvite(context.Background(), inv, "old"); !errors.Is(err, ErrConflict) {
		t.Fatalf("changed concurrently: %v", err)
	}
	gone, _ := newFakeStore(t, canceled(`[{"Code":"None"},{"Code":"ConditionalCheckFailed"}]`))
	if err := gone.PutInvite(context.Background(), inv, ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("trip gone: %v", err)
	}
	ok, f := newFakeStore(t, nil)
	if err := ok.PutInvite(context.Background(), inv, "old"); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(f.calls[0].Body)
	if s := string(raw); !strings.Contains(s, `"INVITE#old"`) || !strings.Contains(s, `"INVITE#new"`) || !strings.Contains(s, `inviteCode = :prev`) {
		t.Fatalf("rotation request: %s", s)
	}

	notMember, _ := newFakeStore(t, canceled(`[{"Code":"ConditionalCheckFailed"},{"Code":"None"},{"Code":"None"}]`))
	if err := notMember.RemoveMember(context.Background(), "trip-1", "user-2", nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("remove non-member: %v", err)
	}
}

func TestRemoveMemberRotation(t *testing.T) {
	rot := &Rotation{New: Invite{Code: "new", TripID: "trip-1", CreatedBy: "owner", CreatedAt: time.Unix(0, 0).UTC()}, Previous: "old"}

	// Leaving: three items, no invite changes.
	leave, f := newFakeStore(t, nil)
	if err := leave.RemoveMember(context.Background(), "trip-1", "user-2", nil); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(f.calls[0].Body)
	if s := string(raw); strings.Contains(s, "INVITE#") || strings.Contains(s, "inviteCode") {
		t.Fatalf("leave touched the invite: %s", s)
	}

	// Removal: the same transaction swaps the invite, guarded by the old code.
	remove, f := newFakeStore(t, nil)
	if err := remove.RemoveMember(context.Background(), "trip-1", "user-2", rot); err != nil {
		t.Fatal(err)
	}
	raw, _ = json.Marshal(f.calls[0].Body)
	s := string(raw)
	for _, want := range []string{`"MEMBER#user-2"`, `"USER#user-2"`, `inviteCode = :new`, `inviteCode = :prev`, `"INVITE#old"`, `"INVITE#new"`} {
		if !strings.Contains(s, want) {
			t.Errorf("removal lacks %s: %s", want, s)
		}
	}
	if n := len(f.calls[0].Body["TransactItems"].([]any)); n != 5 {
		t.Errorf("removal has %d items, want 5", n)
	}

	changed, _ := newFakeStore(t, canceled(`[{"Code":"None"},{"Code":"None"},{"Code":"ConditionalCheckFailed","Item":{"inviteCode":{"S":"other"}}},{"Code":"None"},{"Code":"None"}]`))
	if err := changed.RemoveMember(context.Background(), "trip-1", "user-2", rot); !errors.Is(err, ErrConflict) {
		t.Fatalf("invite changed concurrently: %v", err)
	}
	gone, _ := newFakeStore(t, canceled(`[{"Code":"None"},{"Code":"None"},{"Code":"ConditionalCheckFailed"},{"Code":"None"},{"Code":"None"}]`))
	if err := gone.RemoveMember(context.Background(), "trip-1", "user-2", rot); !errors.Is(err, ErrNotFound) {
		t.Fatalf("trip gone: %v", err)
	}
}
