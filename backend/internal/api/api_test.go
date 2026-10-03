package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/contracttest"
	"github.com/a-godura/picture-ware/backend/internal/photos"
)

// fakeStore is an in-memory Store.
type fakeStore struct {
	trips   map[string]photos.Trip
	members map[string]bool // "tripID/userID"
	photos  map[string]photos.Photo

	memberInfo map[string]photos.Member // "tripID/userID", set by CreateTrip/AddMember
	invites    map[string]photos.Invite // by code
	profiles   map[string]photos.Profile
	raceInvite *photos.Invite // PutInvite: someone else's invite lands first, once
	removeRace *photos.Invite // RemoveMember: someone rotates the invite first, once

	err       error // returned by every method when set
	memberErr error
	deleted   []string
	lastLimit int
}

func newStore() *fakeStore {
	return &fakeStore{trips: map[string]photos.Trip{}, members: map[string]bool{}, photos: map[string]photos.Photo{}}
}

// withTrip adds a trip with the given members (the first is the creator).
func (f *fakeStore) withTrip(id string, users ...string) *fakeStore {
	f.trips[id] = photos.Trip{ID: id, Name: "Trip " + id, StartDate: "2026-10-01", CreatedBy: users[0], CreatedAt: fixedNow}
	for _, u := range users {
		f.members[id+"/"+u] = true
	}
	return f
}

func (f *fakeStore) withPhoto(p photos.Photo) *fakeStore {
	f.photos[p.TripID+"/"+p.ID] = p
	return f
}

func (f *fakeStore) CreateTrip(_ context.Context, t photos.Trip, owner photos.Member) error {
	if f.err != nil {
		return f.err
	}
	t.MemberCount = 1
	f.trips[t.ID] = t
	f.members[t.ID+"/"+owner.UserID] = true
	f.info()[t.ID+"/"+owner.UserID] = owner
	return nil
}

func (f *fakeStore) ListTrips(_ context.Context, userID string) ([]photos.Trip, error) {
	var out []photos.Trip
	for id, t := range f.trips {
		if f.members[id+"/"+userID] {
			out = append(out, t)
		}
	}
	return out, f.err
}

func (f *fakeStore) GetTrip(_ context.Context, tripID string) (photos.Trip, error) {
	if f.err != nil {
		return photos.Trip{}, f.err
	}
	t, ok := f.trips[tripID]
	if !ok {
		return t, photos.ErrNotFound
	}
	return t, nil
}

func (f *fakeStore) IsMember(_ context.Context, tripID, userID string) (bool, error) {
	return f.members[tripID+"/"+userID], f.memberErr
}

func (f *fakeStore) PutPhoto(_ context.Context, p photos.Photo) error {
	if f.err != nil {
		return f.err
	}
	f.photos[p.TripID+"/"+p.ID] = p
	return nil
}

func (f *fakeStore) GetPhoto(_ context.Context, tripID, id string) (photos.Photo, error) {
	if f.err != nil {
		return photos.Photo{}, f.err
	}
	p, ok := f.photos[tripID+"/"+id]
	if !ok {
		return p, photos.ErrNotFound
	}
	return p, nil
}

// ListReadyPhotos pages like DynamoStore: ready photos sorted by listing key,
// cursor = encoded key of the last photo returned.
func (f *fakeStore) ListReadyPhotos(_ context.Context, tripID string, limit int, cursor string) ([]photos.Photo, string, error) {
	f.lastLimit = limit
	if f.err != nil {
		return nil, "", f.err
	}
	sortKey := func(p photos.Photo) string { return "READY#" + photos.ListOrder(p) + "#" + p.ID }
	var after string
	if cursor != "" {
		var err error
		if after, err = photos.DecodeCursor(cursor); err != nil {
			return nil, "", err
		}
	}
	var all []photos.Photo
	for _, p := range f.photos {
		if p.TripID == tripID && p.Status == photos.StatusReady && sortKey(p) > after {
			all = append(all, p)
		}
	}
	sort.Slice(all, func(i, j int) bool { return sortKey(all[i]) < sortKey(all[j]) })
	if len(all) <= limit {
		return all, "", nil
	}
	page := all[:limit]
	return page, photos.EncodeCursor(sortKey(page[limit-1])), nil
}

func (f *fakeStore) DeletePhoto(_ context.Context, p photos.Photo) error {
	if f.err != nil {
		return f.err
	}
	tripID, id := p.TripID, p.ID
	if _, ok := f.photos[tripID+"/"+id]; !ok {
		return photos.ErrNotFound
	}
	delete(f.photos, tripID+"/"+id)
	f.deleted = append(f.deleted, tripID+"/"+id)
	return nil
}

type fakeObjects struct {
	deleted []string
	err     error
}

func (f *fakeObjects) Delete(_ context.Context, key string) error {
	if f.err != nil {
		return f.err
	}
	f.deleted = append(f.deleted, key)
	return nil
}

type fakePresigner struct {
	uploadErr error
	getErr    error
}

func (f *fakePresigner) PresignUpload(_ context.Context, key, ct string) (photos.Upload, error) {
	if f.uploadErr != nil {
		return photos.Upload{}, f.uploadErr
	}
	return photos.Upload{URL: "https://bucket.example", Fields: map[string]string{"key": key, "Content-Type": ct, "policy": "cG9saWN5"}}, nil
}

func (f *fakePresigner) PresignGet(_ context.Context, key string) (string, error) {
	return "https://get.example/" + key, f.getErr
}

var fixedNow = time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)

const (
	testUser  = "8f0b2c1e-1111-4a5b-9c3d-abcdef012345"
	otherUser = "0a0a0a0a-2222-4b4b-8c8c-0123456789ab"
	tripID    = "7d7d7d7d-3333-4c4c-9d9d-0123456789ab"
)

// authed returns a request as API Gateway's JWT authorizer would pass it for
// an access token belonging to sub.
func authed(routeKey, sub string) events.APIGatewayV2HTTPRequest {
	req := events.APIGatewayV2HTTPRequest{RouteKey: routeKey}
	req.RequestContext.Authorizer = &events.APIGatewayV2HTTPRequestContextAuthorizerDescription{
		JWT: &events.APIGatewayV2HTTPRequestContextAuthorizerJWTDescription{
			Claims: map[string]string{"sub": sub, "token_use": "access", "client_id": "client"},
		},
	}
	return req
}

func inTrip(routeKey, sub, trip string, extra map[string]string) events.APIGatewayV2HTTPRequest {
	req := authed(routeKey, sub)
	req.PathParameters = map[string]string{"tripId": trip}
	for k, v := range extra {
		req.PathParameters[k] = v
	}
	return req
}

type harness struct {
	store   *fakeStore
	presign *fakePresigner
	objects *fakeObjects
	codes   int // invite codes handed out
	h       *Handler
}

func newHarness(s *fakeStore) *harness {
	hs := &harness{store: s, presign: &fakePresigner{}, objects: &fakeObjects{}}
	hs.h = &Handler{
		Store: s, Presigner: hs.presign, Objects: hs.objects,
		NewID: func() string { return "id-1" }, NewCode: hs.newCode, Now: func() time.Time { return fixedNow },
	}
	return hs
}

func (hs *harness) do(t *testing.T, req events.APIGatewayV2HTTPRequest) events.APIGatewayV2HTTPResponse {
	t.Helper()
	resp, err := hs.h.Handle(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	contracttest.Check(t, req, resp)
	return resp
}

func errMsg(t *testing.T, body string) string {
	t.Helper()
	var e struct{ Error string }
	if err := json.Unmarshal([]byte(body), &e); err != nil || e.Error == "" {
		t.Fatalf("body %q is not a JSON error: %v", body, err)
	}
	return e.Error
}

func expectStatus(t *testing.T, resp events.APIGatewayV2HTTPResponse, want int) {
	t.Helper()
	if resp.StatusCode != want {
		t.Fatalf("status = %d, want %d (body %s)", resp.StatusCode, want, resp.Body)
	}
	if want >= 400 {
		errMsg(t, resp.Body)
	}
}

func TestCreateTrip(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		b64        bool
		storeErr   error
		wantStatus int
		wantErrSub string
	}{
		{name: "ok", body: `{"name":"  Lisbon  ","startDate":"2026-10-01","endDate":"2026-10-07"}`, wantStatus: http.StatusCreated},
		{name: "ok no end date", body: `{"name":"Birthday","startDate":"2026-10-03"}`, wantStatus: http.StatusCreated},
		{name: "ok base64", body: `{"name":"x","startDate":"2026-10-03"}`, b64: true, wantStatus: http.StatusCreated},
		{name: "blank name", body: `{"name":"   ","startDate":"2026-10-03"}`, wantStatus: http.StatusBadRequest, wantErrSub: "name"},
		{name: "long name", body: `{"name":"` + strings.Repeat("a", 101) + `","startDate":"2026-10-03"}`, wantStatus: http.StatusBadRequest, wantErrSub: "name"},
		{name: "bad start", body: `{"name":"x","startDate":"10/03/2026"}`, wantStatus: http.StatusBadRequest, wantErrSub: "startDate"},
		{name: "missing start", body: `{"name":"x"}`, wantStatus: http.StatusBadRequest, wantErrSub: "startDate"},
		{name: "end before start", body: `{"name":"x","startDate":"2026-10-03","endDate":"2026-10-02"}`, wantStatus: http.StatusBadRequest, wantErrSub: "endDate"},
		{name: "unknown field", body: `{"name":"x","startDate":"2026-10-03","x":1}`, wantStatus: http.StatusBadRequest},
		{name: "store error", body: `{"name":"x","startDate":"2026-10-03"}`, storeErr: errors.New("boom"), wantStatus: http.StatusInternalServerError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newStore()
			s.err = tt.storeErr
			hs := newHarness(s)
			req := authed("POST /trips", testUser)
			req.Body, req.IsBase64Encoded = tt.body, tt.b64
			if tt.b64 {
				req.Body = base64.StdEncoding.EncodeToString([]byte(tt.body))
			}
			resp := hs.do(t, req)
			expectStatus(t, resp, tt.wantStatus)
			if tt.wantStatus != http.StatusCreated {
				if msg := errMsg(t, resp.Body); !strings.Contains(msg, tt.wantErrSub) {
					t.Fatalf("error %q does not contain %q", msg, tt.wantErrSub)
				}
				return
			}
			var got TripView
			if err := json.Unmarshal([]byte(resp.Body), &got); err != nil {
				t.Fatal(err)
			}
			if got.ID != "id-1" || got.CreatedBy != testUser || strings.TrimSpace(got.Name) != got.Name || got.Name == "" {
				t.Fatalf("unexpected trip %+v", got)
			}
			if !s.members["id-1/"+testUser] {
				t.Fatal("creator is not a member")
			}
		})
	}
}

func TestListTrips(t *testing.T) {
	s := newStore().withTrip("old", testUser).withTrip("new", testUser).withTrip("theirs", otherUser)
	s.trips["old"] = photos.Trip{ID: "old", Name: "Old", StartDate: "2025-01-01", CreatedBy: testUser}
	s.trips["new"] = photos.Trip{ID: "new", Name: "New", StartDate: "2026-09-01", CreatedBy: testUser}
	resp := newHarness(s).do(t, authed("GET /trips", testUser))
	expectStatus(t, resp, http.StatusOK)
	var got TripList
	if err := json.Unmarshal([]byte(resp.Body), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Trips) != 2 || got.Trips[0].ID != "new" || got.Trips[1].ID != "old" {
		t.Fatalf("trips = %+v, want [new old]", got.Trips)
	}
	if got.Trips[0].EndDate != nil {
		t.Fatal("missing end date should be null")
	}

	resp = newHarness(newStore()).do(t, authed("GET /trips", testUser))
	expectStatus(t, resp, http.StatusOK)
	if !strings.Contains(resp.Body, `"trips":[]`) {
		t.Fatalf("empty list body = %s", resp.Body)
	}

	bad := newStore()
	bad.err = errors.New("boom")
	expectStatus(t, newHarness(bad).do(t, authed("GET /trips", testUser)), http.StatusInternalServerError)
}

func TestTripAccess(t *testing.T) {
	routes := []struct {
		route string
		extra map[string]string
		body  string
	}{
		{"GET /trips/{tripId}", nil, ""},
		{"GET /trips/{tripId}/photos", nil, ""},
		{"POST /trips/{tripId}/photos", nil, `{"lat":1,"lng":1,"contentType":"image/jpeg"}`},
		{"DELETE /trips/{tripId}/photos/{photoId}", map[string]string{"photoId": "p1"}, ""},
	}
	for _, r := range routes {
		t.Run(r.route, func(t *testing.T) {
			// A non-member gets 404, as if the trip didn't exist.
			s := newStore().withTrip(tripID, testUser).withPhoto(photos.Photo{TripID: tripID, ID: "p1", UploaderID: testUser, Status: photos.StatusReady})
			hs := newHarness(s)
			req := inTrip(r.route, otherUser, tripID, r.extra)
			req.Body = r.body
			expectStatus(t, hs.do(t, req), http.StatusNotFound)
			if len(hs.objects.deleted) != 0 || len(s.deleted) != 0 || len(s.photos) != 1 {
				t.Fatal("non-member changed the trip")
			}

			// Malformed trip id.
			expectStatus(t, hs.do(t, inTrip(r.route, testUser, "../x", r.extra)), http.StatusNotFound)

			// Membership lookup failure.
			s.memberErr = errors.New("boom")
			expectStatus(t, hs.do(t, inTrip(r.route, testUser, tripID, r.extra)), http.StatusInternalServerError)
		})
	}
}

func TestGetTrip(t *testing.T) {
	s := newStore().withTrip(tripID, testUser, otherUser)
	resp := newHarness(s).do(t, inTrip("GET /trips/{tripId}", otherUser, tripID, nil))
	expectStatus(t, resp, http.StatusOK)
	var got TripView
	if err := json.Unmarshal([]byte(resp.Body), &got); err != nil || got.ID != tripID {
		t.Fatalf("got %+v (%v)", got, err)
	}
}

func TestCreatePhoto(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		storeErr   error
		uploadErr  error
		wantStatus int
		wantErrSub string
	}{
		{name: "ok", body: `{"lat":37.7,"lng":-122.4,"contentType":"image/jpeg","takenAt":"2026-09-01T10:00:00Z"}`, wantStatus: http.StatusCreated},
		{name: "ok heic no takenAt", body: `{"lat":0,"lng":0,"contentType":"image/heic"}`, wantStatus: http.StatusCreated},
		{name: "invalid json", body: `{`, wantStatus: http.StatusBadRequest, wantErrSub: "JSON"},
		{name: "lat out of range", body: `{"lat":91,"lng":1,"contentType":"image/jpeg"}`, wantStatus: http.StatusBadRequest, wantErrSub: "lat"},
		{name: "bad content type", body: `{"lat":1,"lng":1,"contentType":"image/png"}`, wantStatus: http.StatusBadRequest, wantErrSub: "contentType"},
		{name: "too large", body: `{"lat":1,"lng":1,"contentType":"image/jpeg","takenAt":"` + strings.Repeat("x", 5000) + `"}`, wantStatus: http.StatusRequestEntityTooLarge},
		{name: "store error", body: `{"lat":1,"lng":1,"contentType":"image/jpeg"}`, storeErr: errors.New("boom"), wantStatus: http.StatusInternalServerError},
		{name: "presign error", body: `{"lat":1,"lng":1,"contentType":"image/jpeg"}`, uploadErr: errors.New("boom"), wantStatus: http.StatusInternalServerError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newStore().withTrip(tripID, otherUser, testUser)
			hs := newHarness(s)
			s.err, hs.presign.uploadErr = tt.storeErr, tt.uploadErr
			req := inTrip("POST /trips/{tripId}/photos", testUser, tripID, nil)
			req.Body = tt.body
			resp := hs.do(t, req)
			expectStatus(t, resp, tt.wantStatus)
			if tt.wantStatus != http.StatusCreated {
				if msg := errMsg(t, resp.Body); !strings.Contains(msg, tt.wantErrSub) {
					t.Fatalf("error %q does not contain %q", msg, tt.wantErrSub)
				}
				if tt.wantStatus < 500 && len(s.photos) != 0 {
					t.Fatal("photo stored on client error")
				}
				return
			}
			var got CreateResponse
			if err := json.Unmarshal([]byte(resp.Body), &got); err != nil {
				t.Fatal(err)
			}
			if got.ID != "id-1" || got.Upload.Fields["key"] != "trips/"+tripID+"/id-1" {
				t.Fatalf("unexpected response %+v", got)
			}
			stored := s.photos[tripID+"/id-1"]
			if stored.TripID != tripID || stored.UploaderID != testUser || stored.Status != photos.StatusPending || !stored.CreatedAt.Equal(fixedNow) {
				t.Fatalf("unexpected stored photo %+v", stored)
			}
		})
	}
}

func TestListPhotos(t *testing.T) {
	early := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	late := early.Add(time.Hour)
	s := newStore().withTrip(tripID, testUser, otherUser).
		withPhoto(photos.Photo{TripID: tripID, ID: "late", UploaderID: otherUser, TakenAt: &late, CreatedAt: fixedNow, Status: photos.StatusReady}).
		withPhoto(photos.Photo{TripID: tripID, ID: "undated", UploaderID: testUser, CreatedAt: fixedNow, Status: photos.StatusReady}).
		withPhoto(photos.Photo{TripID: tripID, ID: "early", UploaderID: testUser, TakenAt: &early, CreatedAt: fixedNow.Add(time.Hour), Status: photos.StatusReady}).
		withPhoto(photos.Photo{TripID: tripID, ID: "pending", UploaderID: testUser, Status: photos.StatusPending})
	hs := newHarness(s)
	resp := hs.do(t, inTrip("GET /trips/{tripId}/photos", testUser, tripID, nil))
	expectStatus(t, resp, http.StatusOK)
	var got ListResponse
	if err := json.Unmarshal([]byte(resp.Body), &got); err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, p := range got.Photos {
		ids = append(ids, p.ID)
		if p.ImageURL != "https://get.example/trips/"+tripID+"/"+p.ID {
			t.Fatalf("imageUrl %q", p.ImageURL)
		}
	}
	if strings.Join(ids, ",") != "early,late,undated" {
		t.Fatalf("order = %v, want capture order with undated last and pending hidden", ids)
	}
	if got.Photos[1].UploaderID != otherUser {
		t.Fatal("uploaderId missing")
	}

	hs.presign.getErr = errors.New("boom")
	expectStatus(t, hs.do(t, inTrip("GET /trips/{tripId}/photos", testUser, tripID, nil)), http.StatusInternalServerError)

	empty := newHarness(newStore().withTrip(tripID, testUser)).do(t, inTrip("GET /trips/{tripId}/photos", testUser, tripID, nil))
	if !strings.Contains(empty.Body, `"photos":[]`) {
		t.Fatalf("empty body = %s", empty.Body)
	}
}

func TestListPhotosPagination(t *testing.T) {
	s := newStore().withTrip(tripID, testUser)
	var want []string
	for i := range 5 {
		taken := fixedNow.Add(time.Duration(i) * time.Minute)
		id := fmt.Sprintf("p%d", i)
		want = append(want, id)
		s.withPhoto(photos.Photo{TripID: tripID, ID: id, UploaderID: testUser, TakenAt: &taken, CreatedAt: fixedNow, Status: photos.StatusReady})
	}
	s.withPhoto(photos.Photo{TripID: tripID, ID: "pending", UploaderID: testUser, Status: photos.StatusPending})
	hs := newHarness(s)
	list := func(query map[string]string) (ListResponse, events.APIGatewayV2HTTPResponse) {
		req := inTrip("GET /trips/{tripId}/photos", testUser, tripID, nil)
		req.QueryStringParameters = query
		resp := hs.do(t, req)
		var got ListResponse
		if resp.StatusCode == http.StatusOK {
			if err := json.Unmarshal([]byte(resp.Body), &got); err != nil {
				t.Fatal(err)
			}
		}
		return got, resp
	}

	// Default page size; one page, null cursor.
	got, resp := list(nil)
	expectStatus(t, resp, http.StatusOK)
	if s.lastLimit != DefaultPageSize || len(got.Photos) != 5 || got.NextCursor != nil || !strings.Contains(resp.Body, `"nextCursor":null`) {
		t.Fatalf("limit %d, body %s", s.lastLimit, resp.Body)
	}

	// Walk pages of 2: 2 + 2 + 1, order kept across pages.
	var ids []string
	query := map[string]string{"limit": "2"}
	for pages := 0; ; pages++ {
		if pages > 5 {
			t.Fatal("pagination doesn't end")
		}
		got, resp := list(query)
		expectStatus(t, resp, http.StatusOK)
		for _, p := range got.Photos {
			ids = append(ids, p.ID)
		}
		if got.NextCursor == nil {
			break
		}
		query = map[string]string{"limit": "2", "cursor": *got.NextCursor}
	}
	if strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Fatalf("paged ids = %v, want %v", ids, want)
	}

	for _, q := range []map[string]string{
		{"limit": "0"}, {"limit": "501"}, {"limit": "ten"}, {"limit": ""},
		{"cursor": "not base64!"}, {"cursor": photos.EncodeCursor("MEMBER#" + testUser)},
	} {
		_, resp := list(q)
		expectStatus(t, resp, http.StatusBadRequest)
	}
	_, resp = list(map[string]string{"limit": "500"})
	expectStatus(t, resp, http.StatusOK)
}

func TestDeletePhoto(t *testing.T) {
	const route = "DELETE /trips/{tripId}/photos/{photoId}"
	setup := func() *harness {
		return newHarness(newStore().withTrip(tripID, testUser, otherUser).
			withPhoto(photos.Photo{TripID: tripID, ID: "p1", UploaderID: testUser, Status: photos.StatusReady}))
	}
	tests := []struct {
		name        string
		user        string
		photo       string
		objectErr   error
		wantStatus  int
		wantDeleted bool
	}{
		{name: "uploader deletes", user: testUser, photo: "p1", wantStatus: http.StatusNoContent, wantDeleted: true},
		{name: "other member forbidden", user: otherUser, photo: "p1", wantStatus: http.StatusForbidden},
		{name: "missing", user: testUser, photo: "nope", wantStatus: http.StatusNotFound},
		{name: "invalid id", user: testUser, photo: "../p1", wantStatus: http.StatusNotFound},
		{name: "object delete fails keeps record", user: testUser, photo: "p1", objectErr: errors.New("boom"), wantStatus: http.StatusInternalServerError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			hs := setup()
			hs.objects.err = tt.objectErr
			resp := hs.do(t, inTrip(route, tt.user, tripID, map[string]string{"photoId": tt.photo}))
			expectStatus(t, resp, tt.wantStatus)
			if tt.wantStatus == http.StatusNoContent && resp.Body != "" {
				t.Fatalf("204 body = %q", resp.Body)
			}
			_, stillThere := hs.store.photos[tripID+"/p1"]
			if stillThere == tt.wantDeleted {
				t.Fatalf("record deleted = %v, want %v", !stillThere, tt.wantDeleted)
			}
			if tt.wantDeleted && (len(hs.objects.deleted) != 1 || hs.objects.deleted[0] != "trips/"+tripID+"/p1") {
				t.Fatalf("object deletes = %v", hs.objects.deleted)
			}
		})
	}
}

func TestUserID(t *testing.T) {
	withClaims := func(c map[string]string) events.APIGatewayV2HTTPRequest {
		req := events.APIGatewayV2HTTPRequest{}
		req.RequestContext.Authorizer = &events.APIGatewayV2HTTPRequestContextAuthorizerDescription{
			JWT: &events.APIGatewayV2HTTPRequestContextAuthorizerJWTDescription{Claims: c},
		}
		return req
	}
	noJWT := events.APIGatewayV2HTTPRequest{}
	noJWT.RequestContext.Authorizer = &events.APIGatewayV2HTTPRequestContextAuthorizerDescription{}
	tests := []struct {
		name   string
		req    events.APIGatewayV2HTTPRequest
		want   string
		wantOK bool
	}{
		{name: "access token", req: withClaims(map[string]string{"sub": testUser, "token_use": "access"}), want: testUser, wantOK: true},
		{name: "no authorizer", req: events.APIGatewayV2HTTPRequest{}},
		{name: "no jwt", req: noJWT},
		{name: "nil claims", req: withClaims(nil)},
		{name: "missing sub", req: withClaims(map[string]string{"token_use": "access"})},
		{name: "empty sub", req: withClaims(map[string]string{"sub": "", "token_use": "access"})},
		{name: "id token rejected", req: withClaims(map[string]string{"sub": testUser, "token_use": "id"})},
		{name: "missing token_use", req: withClaims(map[string]string{"sub": testUser})},
		{name: "sub with slash", req: withClaims(map[string]string{"sub": "a/b", "token_use": "access"})},
		{name: "sub with dots", req: withClaims(map[string]string{"sub": "..", "token_use": "access"})},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := UserID(tt.req)
			if got != tt.want || ok != tt.wantOK {
				t.Fatalf("UserID = %q, %v; want %q, %v", got, ok, tt.want, tt.wantOK)
			}
		})
	}
}

func TestMissingClaimsUnauthorized(t *testing.T) {
	for _, route := range []string{"GET /trips", "POST /trips", "GET /trips/{tripId}/photos", "POST /trips/{tripId}/photos"} {
		t.Run(route, func(t *testing.T) {
			s := newStore().withTrip(tripID, testUser)
			req := events.APIGatewayV2HTTPRequest{RouteKey: route, PathParameters: map[string]string{"tripId": tripID}, Body: `{"name":"x","startDate":"2026-10-03"}`}
			expectStatus(t, newHarness(s).do(t, req), http.StatusUnauthorized)
			if len(s.trips) != 1 || len(s.photos) != 0 {
				t.Fatal("store changed without a user")
			}
		})
	}
}

func TestUnknownRoute(t *testing.T) {
	expectStatus(t, newHarness(newStore()).do(t, authed("DELETE /trips", testUser)), http.StatusNotFound)

	// The legacy /photos routes are served by internal/legacy/api, not this
	// handler. Called directly: they're documented routes whose contract has
	// no 404, so the contract check doesn't apply to this handler's answer.
	resp, err := newHarness(newStore()).h.Handle(context.Background(), authed("GET /photos", testUser))
	if err != nil {
		t.Fatal(err)
	}
	expectStatus(t, resp, http.StatusNotFound)
}
