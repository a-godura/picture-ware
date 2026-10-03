package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

// ---------- fakes ----------

func (f *fakeStore) info() map[string]photos.Member {
	if f.memberInfo == nil {
		f.memberInfo = map[string]photos.Member{}
	}
	return f.memberInfo
}

func (f *fakeStore) inv() map[string]photos.Invite {
	if f.invites == nil {
		f.invites = map[string]photos.Invite{}
	}
	return f.invites
}

func (f *fakeStore) ListMembers(_ context.Context, tripID string) ([]photos.Member, error) {
	var out []photos.Member
	for k := range f.members {
		trip, user, _ := strings.Cut(k, "/")
		if trip == tripID {
			m, ok := f.info()[k]
			if !ok {
				m = photos.Member{UserID: user}
			}
			out = append(out, m)
		}
	}
	return out, f.err
}

func (f *fakeStore) AddMember(_ context.Context, t photos.Trip, m photos.Member, code string) error {
	if f.err != nil {
		return f.err
	}
	cur, ok := f.trips[t.ID]
	switch {
	case f.members[t.ID+"/"+m.UserID]:
		return photos.ErrAlreadyMember
	case !ok || cur.InviteCode != code:
		return photos.ErrNotFound
	case cur.Members() >= photos.MaxMembers:
		return photos.ErrTripFull
	}
	f.members[t.ID+"/"+m.UserID] = true
	f.info()[t.ID+"/"+m.UserID] = m
	cur.MemberCount = cur.Members() + 1
	f.trips[t.ID] = cur
	return nil
}

func (f *fakeStore) RemoveMember(_ context.Context, tripID, userID string, rotate *photos.Rotation) error {
	if f.err != nil {
		return f.err
	}
	if !f.members[tripID+"/"+userID] {
		return photos.ErrNotFound
	}
	if r := f.removeRace; r != nil { // someone rotates just before us, once
		f.removeRace = nil
		t := f.trips[tripID]
		delete(f.inv(), t.InviteCode)
		f.inv()[r.Code] = *r
		t.InviteCode = r.Code
		f.trips[tripID] = t
	}
	if rotate != nil {
		t := f.trips[tripID]
		if t.InviteCode != rotate.Previous {
			return photos.ErrConflict
		}
		delete(f.inv(), rotate.Previous)
		f.inv()[rotate.New.Code] = rotate.New
		t.InviteCode = rotate.New.Code
		f.trips[tripID] = t
	}
	delete(f.members, tripID+"/"+userID)
	delete(f.info(), tripID+"/"+userID)
	t := f.trips[tripID]
	t.MemberCount = t.Members() - 1
	f.trips[tripID] = t
	return nil
}

func (f *fakeStore) GetInvite(_ context.Context, code string) (photos.Invite, error) {
	if f.err != nil {
		return photos.Invite{}, f.err
	}
	inv, ok := f.inv()[code]
	if !ok {
		return inv, photos.ErrNotFound
	}
	return inv, nil
}

func (f *fakeStore) PutInvite(_ context.Context, inv photos.Invite, previous string) error {
	if f.err != nil {
		return f.err
	}
	t, ok := f.trips[inv.TripID]
	if !ok {
		return photos.ErrNotFound
	}
	if r := f.raceInvite; r != nil {
		f.raceInvite = nil
		f.inv()[r.Code] = *r
		t.InviteCode = r.Code
		f.trips[inv.TripID] = t
	}
	if t.InviteCode != previous {
		return photos.ErrConflict
	}
	delete(f.inv(), previous)
	f.inv()[inv.Code] = inv
	t.InviteCode = inv.Code
	f.trips[inv.TripID] = t
	return nil
}

func (f *fakeStore) GetProfile(_ context.Context, userID string) (photos.Profile, error) {
	if f.err != nil {
		return photos.Profile{}, f.err
	}
	if p, ok := f.profiles[userID]; ok {
		return p, nil
	}
	return photos.Profile{UserID: userID}, nil
}

func (f *fakeStore) PutProfile(_ context.Context, p photos.Profile) error {
	if f.err != nil {
		return f.err
	}
	if f.profiles == nil {
		f.profiles = map[string]photos.Profile{}
	}
	f.profiles[p.UserID] = p
	return nil
}

func (f *fakeStore) DisplayNames(_ context.Context, userIDs []string) (map[string]string, error) {
	out := map[string]string{}
	for _, id := range userIDs {
		if p := f.profiles[id]; p.DisplayName != "" {
			out[id] = p.DisplayName
		}
	}
	return out, f.err
}

// newCode hands out distinct, well-formed invite codes.
func (hs *harness) newCode() (string, error) {
	hs.codes++
	return strings.Repeat("a", 25) + string(rune('a'+hs.codes)), nil
}

// ---------- helpers ----------

const thirdUser = "3c3c3c3c-4444-4d4d-9e9e-0123456789ab"

func atCode(routeKey, sub, code string) events.APIGatewayV2HTTPRequest {
	req := authed(routeKey, sub)
	req.PathParameters = map[string]string{"code": code}
	return req
}

func decode[T any](t *testing.T, resp events.APIGatewayV2HTTPResponse) T {
	t.Helper()
	var v T
	if err := json.Unmarshal([]byte(resp.Body), &v); err != nil {
		t.Fatalf("decode %s: %v", resp.Body, err)
	}
	return v
}

// createTrip makes testUser the owner of a new trip through the API.
func (hs *harness) createTrip(t *testing.T) string {
	t.Helper()
	req := authed("POST /trips", testUser)
	req.Body = `{"name":"Lisbon","startDate":"2026-10-01"}`
	resp := hs.do(t, req)
	expectStatus(t, resp, http.StatusCreated)
	return decode[TripView](t, resp).ID
}

func (hs *harness) invite(t *testing.T, sub, trip string) InviteView {
	t.Helper()
	req := inTrip("POST /trips/{tripId}/invite", sub, trip, nil)
	req.RequestContext.DomainName = "api.example.com"
	resp := hs.do(t, req)
	expectStatus(t, resp, http.StatusOK)
	return decode[InviteView](t, resp)
}

// ---------- tests ----------

// The whole flow: share, preview, join, see photos, list members, leave,
// rotate.
func TestInviteFlow(t *testing.T) {
	hs := newHarness(newStore())
	hs.setName(t, testUser, "Ana")
	trip := hs.createTrip(t)
	hs.store.withPhoto(photos.Photo{TripID: trip, ID: "p1", UploaderID: testUser, Status: photos.StatusReady, CreatedAt: fixedNow})

	inv := hs.invite(t, testUser, trip)
	if !photos.ValidInviteCode(inv.Code) || inv.TripID != trip || inv.CreatedBy != testUser {
		t.Fatalf("invite = %+v", inv)
	}
	if inv.URL != "https://api.example.com/j/"+inv.Code || inv.AppURL != "picture-ware://join/"+inv.Code {
		t.Fatalf("urls = %q %q", inv.URL, inv.AppURL)
	}
	if again := hs.invite(t, testUser, trip); again != inv {
		t.Fatalf("second call made a new invite: %+v vs %+v", again, inv)
	}

	// Not a member yet: the trip is invisible, the preview isn't.
	expectStatus(t, hs.do(t, inTrip("GET /trips/{tripId}/photos", otherUser, trip, nil)), http.StatusNotFound)
	resp := hs.do(t, atCode("GET /invites/{code}", otherUser, inv.Code))
	expectStatus(t, resp, http.StatusOK)
	p := decode[InvitePreview](t, resp)
	if p.Trip.ID != trip || p.Trip.Name != "Lisbon" || p.Trip.EndDate != nil || p.OwnerName == nil || *p.OwnerName != "Ana" ||
		p.MemberCount != 1 || p.AlreadyMember {
		t.Fatalf("preview = %s", resp.Body)
	}

	// Join; joining again is a no-op.
	for range 2 {
		resp = hs.do(t, atCode("POST /invites/{code}/accept", otherUser, inv.Code))
		expectStatus(t, resp, http.StatusOK)
		if got := decode[TripView](t, resp); got.ID != trip || got.CreatedBy != testUser {
			t.Fatalf("accept = %s", resp.Body)
		}
	}
	resp = hs.do(t, inTrip("GET /trips/{tripId}/photos", otherUser, trip, nil))
	expectStatus(t, resp, http.StatusOK)
	if got := decode[ListResponse](t, resp); len(got.Photos) != 1 || got.Photos[0].ID != "p1" {
		t.Fatalf("B sees %s", resp.Body)
	}
	if got := decode[TripList](t, hs.do(t, authed("GET /trips", otherUser))); len(got.Trips) != 1 || got.Trips[0].ID != trip {
		t.Fatalf("B's trips = %+v", got)
	}
	p = decode[InvitePreview](t, hs.do(t, atCode("GET /invites/{code}", otherUser, inv.Code)))
	if !p.AlreadyMember || p.MemberCount != 2 {
		t.Fatalf("preview after joining = %+v", p)
	}

	// Members: owner first. B can share the same invite.
	hs.store.info()[trip+"/"+otherUser] = photos.Member{UserID: otherUser, JoinedAt: fixedNow.Add(time.Hour)}
	hs.setName(t, otherUser, "  Ben 🏔️ ")
	resp = hs.do(t, inTrip("GET /trips/{tripId}/members", otherUser, trip, nil))
	expectStatus(t, resp, http.StatusOK)
	ml := decode[MemberList](t, resp)
	if len(ml.Members) != 2 || ml.Members[0].UserID != testUser || ml.Members[0].Role != RoleOwner ||
		ml.Members[1].UserID != otherUser || ml.Members[1].Role != RoleMember || *ml.Members[1].Name != "Ben 🏔️" {
		t.Fatalf("members = %s", resp.Body)
	}
	if got := hs.invite(t, otherUser, trip); got.Code != inv.Code {
		t.Fatalf("member got a different invite %q", got.Code)
	}

	// B leaves and loses access; their photos would stay.
	expectStatus(t, hs.do(t, inTrip("DELETE /trips/{tripId}/members/{userId}", otherUser, trip, map[string]string{"userId": otherUser})), http.StatusNoContent)
	expectStatus(t, hs.do(t, inTrip("GET /trips/{tripId}", otherUser, trip, nil)), http.StatusNotFound)
	if got := decode[TripList](t, hs.do(t, authed("GET /trips", otherUser))); len(got.Trips) != 0 {
		t.Fatalf("B still lists %+v", got)
	}

	// Rotation: owner only; the old code stops working.
	expectStatus(t, hs.do(t, atCode("POST /invites/{code}/accept", thirdUser, inv.Code)), http.StatusOK)
	expectStatus(t, hs.do(t, inTrip("POST /trips/{tripId}/invite/rotate", thirdUser, trip, nil)), http.StatusForbidden)
	resp = hs.do(t, inTrip("POST /trips/{tripId}/invite/rotate", testUser, trip, nil))
	expectStatus(t, resp, http.StatusCreated)
	rotated := decode[InviteView](t, resp)
	if rotated.Code == inv.Code || !photos.ValidInviteCode(rotated.Code) {
		t.Fatalf("rotated = %+v", rotated)
	}
	for _, route := range []string{"GET /invites/{code}", "POST /invites/{code}/accept"} {
		resp = hs.do(t, atCode(route, otherUser, inv.Code))
		expectStatus(t, resp, http.StatusNotFound)
		if msg := errMsg(t, resp.Body); msg != "invite not found" {
			t.Fatalf("%s old code: %q", route, msg)
		}
	}
	expectStatus(t, hs.do(t, atCode("POST /invites/{code}/accept", otherUser, rotated.Code)), http.StatusOK)
	if got := hs.invite(t, otherUser, trip); got.Code != rotated.Code {
		t.Fatalf("invite after rotation = %q, want %q", got.Code, rotated.Code)
	}
}

func TestRemoveMemberRules(t *testing.T) {
	const owner, member, other = testUser, otherUser, thirdUser
	tests := []struct {
		name, caller, target string
		want                 int
		wantErr              string
	}{
		{"member leaves", member, member, http.StatusNoContent, ""},
		{"owner removes member", owner, member, http.StatusNoContent, ""},
		{"owner can't leave", owner, owner, http.StatusConflict, "creator"},
		{"member can't remove owner", member, owner, http.StatusForbidden, "only the trip's creator"},
		{"member can't remove member", member, other, http.StatusForbidden, "only the trip's creator"},
		{"owner removes non-member", owner, "9b9b9b9b-5555-4e4e-8f8f-0123456789ab", http.StatusNotFound, "member not found"},
		{"malformed id", owner, "../x", http.StatusNotFound, "member not found"},
		{"outsider", "9b9b9b9b-5555-4e4e-8f8f-0123456789ab", member, http.StatusNotFound, "trip not found"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			hs := newHarness(newStore().withTrip(tripID, owner, member, other))
			resp := hs.do(t, inTrip("DELETE /trips/{tripId}/members/{userId}", tt.caller, tripID, map[string]string{"userId": tt.target}))
			expectStatus(t, resp, tt.want)
			if tt.wantErr != "" {
				if msg := errMsg(t, resp.Body); !strings.Contains(msg, tt.wantErr) {
					t.Fatalf("error %q, want %q", msg, tt.wantErr)
				}
				return
			}
			if hs.store.members[tripID+"/"+tt.target] {
				t.Fatal("still a member")
			}
			expectStatus(t, hs.do(t, inTrip("GET /trips/{tripId}/photos", tt.target, tripID, nil)), http.StatusNotFound)
		})
	}
}

// The owner removing someone rotates the invite in the same step, so they
// can't rejoin with the link they had; leaving doesn't.
func TestRemoveRotatesInvite(t *testing.T) {
	hs := newHarness(newStore())
	trip := hs.createTrip(t)
	inv := hs.invite(t, testUser, trip)
	for _, u := range []string{otherUser, thirdUser} {
		expectStatus(t, hs.do(t, atCode("POST /invites/{code}/accept", u, inv.Code)), http.StatusOK)
	}

	// Leaving keeps the link.
	expectStatus(t, hs.do(t, inTrip("DELETE /trips/{tripId}/members/{userId}", thirdUser, trip, map[string]string{"userId": thirdUser})), http.StatusNoContent)
	if got := hs.invite(t, testUser, trip); got.Code != inv.Code {
		t.Fatalf("leaving rotated the invite to %q", got.Code)
	}

	// Removal rotates it.
	expectStatus(t, hs.do(t, inTrip("DELETE /trips/{tripId}/members/{userId}", testUser, trip, map[string]string{"userId": otherUser})), http.StatusNoContent)
	for _, route := range []string{"GET /invites/{code}", "POST /invites/{code}/accept"} {
		expectStatus(t, hs.do(t, atCode(route, otherUser, inv.Code)), http.StatusNotFound)
	}
	if hs.store.members[trip+"/"+otherUser] {
		t.Fatal("removed member rejoined with the old code")
	}
	fresh := hs.invite(t, testUser, trip)
	if fresh.Code == inv.Code || fresh.CreatedBy != testUser {
		t.Fatalf("invite after removal = %+v", fresh)
	}
	expectStatus(t, hs.do(t, atCode("POST /invites/{code}/accept", thirdUser, fresh.Code)), http.StatusOK)

	// A concurrent rotation is retried against the new code.
	theirs := photos.Invite{Code: strings.Repeat("z", 26), TripID: trip, CreatedBy: testUser, CreatedAt: fixedNow}
	hs.store.removeRace = &theirs
	expectStatus(t, hs.do(t, inTrip("DELETE /trips/{tripId}/members/{userId}", testUser, trip, map[string]string{"userId": thirdUser})), http.StatusNoContent)
	if got := hs.store.trips[trip].InviteCode; got == theirs.Code || got == fresh.Code {
		t.Fatalf("invite after racing removal = %q", got)
	}
}

func TestAcceptTripFull(t *testing.T) {
	hs := newHarness(newStore())
	trip := hs.createTrip(t)
	inv := hs.invite(t, testUser, trip)
	tr := hs.store.trips[trip]
	tr.MemberCount = photos.MaxMembers
	hs.store.trips[trip] = tr
	resp := hs.do(t, atCode("POST /invites/{code}/accept", otherUser, inv.Code))
	expectStatus(t, resp, http.StatusConflict)
	if hs.store.members[trip+"/"+otherUser] {
		t.Fatal("joined a full trip")
	}
}

func TestInviteCodesNotFound(t *testing.T) {
	hs := newHarness(newStore().withTrip(tripID, testUser))
	for _, code := range []string{"", "short", strings.Repeat("A", 26), strings.Repeat("a", 25) + "1", strings.Repeat("b", 26)} {
		for _, route := range []string{"GET /invites/{code}", "POST /invites/{code}/accept"} {
			resp := hs.do(t, atCode(route, otherUser, code))
			expectStatus(t, resp, http.StatusNotFound)
			if msg := errMsg(t, resp.Body); msg != "invite not found" {
				t.Fatalf("%s %q: %q", route, code, msg)
			}
		}
	}
}

func TestInviteOutsiderAndErrors(t *testing.T) {
	hs := newHarness(newStore().withTrip(tripID, testUser))
	for _, route := range []string{"POST /trips/{tripId}/invite", "POST /trips/{tripId}/invite/rotate", "GET /trips/{tripId}/members"} {
		expectStatus(t, hs.do(t, inTrip(route, otherUser, tripID, nil)), http.StatusNotFound)
	}
	inv := hs.invite(t, testUser, tripID)
	hs.store.err = errors.New("boom")
	for _, req := range []events.APIGatewayV2HTTPRequest{
		atCode("GET /invites/{code}", otherUser, inv.Code),
		atCode("POST /invites/{code}/accept", otherUser, inv.Code),
		inTrip("POST /trips/{tripId}/invite", testUser, tripID, nil),
		inTrip("GET /trips/{tripId}/members", testUser, tripID, nil),
		inTrip("DELETE /trips/{tripId}/members/{userId}", testUser, tripID, map[string]string{"userId": otherUser}),
	} {
		expectStatus(t, hs.do(t, req), http.StatusInternalServerError)
	}
}

// Members who haven't chosen a display name are listed with name null; a
// name chosen later shows up at once, and never anything email-derived.
func TestMemberNames(t *testing.T) {
	hs := newHarness(newStore())
	trip := hs.createTrip(t)
	inv := hs.invite(t, testUser, trip)
	p := decode[InvitePreview](t, hs.do(t, atCode("GET /invites/{code}", otherUser, inv.Code)))
	if p.OwnerName != nil {
		t.Fatalf("ownerName = %q before the owner chose one", *p.OwnerName)
	}
	expectStatus(t, hs.do(t, atCode("POST /invites/{code}/accept", otherUser, inv.Code)), http.StatusOK)
	ml := decode[MemberList](t, hs.do(t, inTrip("GET /trips/{tripId}/members", testUser, trip, nil)))
	if len(ml.Members) != 2 || ml.Members[0].Name != nil || ml.Members[1].Name != nil {
		t.Fatalf("members = %+v", ml)
	}
	hs.setName(t, otherUser, "Ben")
	ml = decode[MemberList](t, hs.do(t, inTrip("GET /trips/{tripId}/members", testUser, trip, nil)))
	if ml.Members[1].Name == nil || *ml.Members[1].Name != "Ben" {
		t.Fatalf("members after naming = %+v", ml)
	}
}

func TestMe(t *testing.T) {
	hs := newHarness(newStore())
	resp := hs.do(t, authed("GET /me", testUser))
	expectStatus(t, resp, http.StatusOK)
	if got := decode[ProfileView](t, resp); got.UserID != testUser || got.DisplayName != nil {
		t.Fatalf("new user's profile = %s", resp.Body)
	}
	for _, tt := range []struct {
		body    string
		want    int
		wantErr string
	}{
		{`{"displayName":""}`, http.StatusBadRequest, "required"},
		{`{"displayName":"   "}`, http.StatusBadRequest, "required"},
		{`{}`, http.StatusBadRequest, "required"},
		{`{"displayName":"` + strings.Repeat("é", 51) + `"}`, http.StatusBadRequest, "at most 50"},
		{`{"displayName":"a\nb"}`, http.StatusBadRequest, "control"},
		{`{"displayName":"Ana","email":"x"}`, http.StatusBadRequest, ""},
		{`{"displayName":"` + strings.Repeat("é", 50) + `"}`, http.StatusOK, ""},
		{`{"displayName":"  Ana  "}`, http.StatusOK, ""},
	} {
		req := authed("PATCH /me", testUser)
		req.Body = tt.body
		resp := hs.do(t, req)
		expectStatus(t, resp, tt.want)
		if tt.wantErr != "" && !strings.Contains(errMsg(t, resp.Body), tt.wantErr) {
			t.Fatalf("%s: error %s", tt.body, resp.Body)
		}
	}
	resp = hs.do(t, authed("GET /me", testUser))
	if got := decode[ProfileView](t, resp); got.DisplayName == nil || *got.DisplayName != "Ana" {
		t.Fatalf("profile after PATCH = %s", resp.Body)
	}
	hs.store.err = errors.New("boom")
	expectStatus(t, hs.do(t, authed("GET /me", testUser)), http.StatusInternalServerError)
}

// setName sets sub's display name through PATCH /me.
func (hs *harness) setName(t *testing.T, sub, name string) {
	t.Helper()
	req := authed("PATCH /me", sub)
	b, _ := json.Marshal(map[string]string{"displayName": name})
	req.Body = string(b)
	expectStatus(t, hs.do(t, req), http.StatusOK)
}

// Someone else creating the trip's first invite at the same moment: both
// callers end up with the same one.
func TestInviteCreateRace(t *testing.T) {
	hs := newHarness(newStore().withTrip(tripID, testUser, otherUser))
	theirs := photos.Invite{Code: strings.Repeat("z", 26), TripID: tripID, CreatedBy: otherUser, CreatedAt: fixedNow}
	hs.store.raceInvite = &theirs
	if got := hs.invite(t, testUser, tripID); got.Code != theirs.Code || got.CreatedBy != otherUser {
		t.Fatalf("got %+v, want theirs", got)
	}
}

func TestLandingPage(t *testing.T) {
	hs := newHarness(newStore())
	code := strings.Repeat("a", 25) + "b"
	// Public: no authorizer context at all.
	req := events.APIGatewayV2HTTPRequest{RouteKey: "GET /j/{code}", PathParameters: map[string]string{"code": code}}
	resp := hs.do(t, req)
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(resp.Headers["Content-Type"], "text/html") {
		t.Fatalf("landing = %d %v", resp.StatusCode, resp.Headers)
	}
	if !strings.Contains(resp.Body, `href="picture-ware://join/`+code+`"`) {
		t.Fatalf("no deep link in %s", resp.Body)
	}
	for _, h := range []string{"Cache-Control", "Referrer-Policy", "X-Robots-Tag", "Content-Security-Policy"} {
		if resp.Headers[h] == "" {
			t.Fatalf("missing %s", h)
		}
	}
	for _, bad := range []string{"", "<script>alert(1)</script>", strings.Repeat("A", 26)} {
		req.PathParameters["code"] = bad
		resp = hs.do(t, req)
		if resp.StatusCode != http.StatusNotFound || strings.Contains(resp.Body, "<script>") || strings.Contains(resp.Body, "picture-ware://") {
			t.Fatalf("landing %q = %d %s", bad, resp.StatusCode, resp.Body)
		}
	}
}
