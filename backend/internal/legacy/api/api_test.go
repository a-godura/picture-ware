package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/legacy/photos"
)

type fakeStore struct {
	put      []photos.Photo
	ready    []photos.Photo // returned only for listUser == testUser
	putErr   error
	listErr  error
	listUser string

	deleted   []string // "userID/id" of successful deletes
	deleteErr error    // returned instead of deleting
	exists    map[string]bool
}

func (f *fakeStore) Put(_ context.Context, p photos.Photo) error {
	if f.putErr != nil {
		return f.putErr
	}
	f.put = append(f.put, p)
	return nil
}

func (f *fakeStore) ListReady(_ context.Context, userID string) ([]photos.Photo, error) {
	f.listUser = userID
	if userID != testUser {
		return nil, f.listErr
	}
	return f.ready, f.listErr
}

func (f *fakeStore) Delete(_ context.Context, userID, id string) error {
	if f.deleteErr != nil {
		return f.deleteErr
	}
	if !f.exists[userID+"/"+id] {
		return photos.ErrNotFound
	}
	f.deleted = append(f.deleted, userID+"/"+id)
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
	gotType   string
}

func (f *fakePresigner) PresignUpload(_ context.Context, key, ct string) (photos.Upload, error) {
	f.gotType = ct
	if f.uploadErr != nil {
		return photos.Upload{}, f.uploadErr
	}
	return photos.Upload{URL: "https://bucket.example", Fields: map[string]string{"key": key, "Content-Type": ct}}, nil
}

func (f *fakePresigner) PresignGet(_ context.Context, key string) (string, error) {
	return "https://get.example/" + key, f.getErr
}

var fixedNow = time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)

const testUser = "8f0b2c1e-1111-4a5b-9c3d-abcdef012345"

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

func newHandler(s *fakeStore, p *fakePresigner) *Handler {
	return &Handler{Store: s, Presigner: p, Objects: &fakeObjects{}, NewID: func() string { return "id-1" }, Now: func() time.Time { return fixedNow }}
}

func errMsg(t *testing.T, body string) string {
	t.Helper()
	var e struct{ Error string }
	if err := json.Unmarshal([]byte(body), &e); err != nil || e.Error == "" {
		t.Fatalf("body %q is not a JSON error: %v", body, err)
	}
	return e.Error
}

func TestCreate(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		b64        bool
		store      *fakeStore
		presigner  *fakePresigner
		wantStatus int
		wantErrSub string
	}{
		{name: "ok", body: `{"lat":37.7,"lng":-122.4,"contentType":"image/jpeg","takenAt":"2026-09-01T10:00:00Z"}`, wantStatus: http.StatusCreated},
		{name: "ok heic no takenAt", body: `{"lat":0,"lng":0,"contentType":"image/heic"}`, wantStatus: http.StatusCreated},
		{name: "ok base64 body", body: `{"lat":1,"lng":1,"contentType":"image/jpeg"}`, b64: true, wantStatus: http.StatusCreated},
		{name: "invalid json", body: `{`, wantStatus: http.StatusBadRequest, wantErrSub: "JSON"},
		{name: "unknown field", body: `{"lat":1,"lng":1,"contentType":"image/jpeg","x":1}`, wantStatus: http.StatusBadRequest},
		{name: "lat out of range", body: `{"lat":91,"lng":1,"contentType":"image/jpeg"}`, wantStatus: http.StatusBadRequest, wantErrSub: "lat"},
		{name: "bad content type", body: `{"lat":1,"lng":1,"contentType":"image/png"}`, wantStatus: http.StatusBadRequest, wantErrSub: "contentType"},
		{name: "too large", body: `{"lat":1,"lng":1,"contentType":"image/jpeg","takenAt":"` + strings.Repeat("x", 5000) + `"}`, wantStatus: http.StatusRequestEntityTooLarge},
		{name: "store error", body: `{"lat":1,"lng":1,"contentType":"image/jpeg"}`, store: &fakeStore{putErr: errors.New("boom")}, wantStatus: http.StatusInternalServerError},
		{name: "presign error", body: `{"lat":1,"lng":1,"contentType":"image/jpeg"}`, presigner: &fakePresigner{uploadErr: errors.New("boom")}, wantStatus: http.StatusInternalServerError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s, p := tt.store, tt.presigner
			if s == nil {
				s = &fakeStore{}
			}
			if p == nil {
				p = &fakePresigner{}
			}
			body := tt.body
			if tt.b64 {
				body = base64.StdEncoding.EncodeToString([]byte(body))
			}
			req := authed("POST /photos", testUser)
			req.Body, req.IsBase64Encoded = body, tt.b64
			resp, err := newHandler(s, p).Handle(context.Background(), req)
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", resp.StatusCode, tt.wantStatus, resp.Body)
			}
			if resp.Headers["Content-Type"] != "application/json" {
				t.Fatalf("content type = %q", resp.Headers["Content-Type"])
			}
			if tt.wantStatus != http.StatusCreated {
				if msg := errMsg(t, resp.Body); !strings.Contains(msg, tt.wantErrSub) {
					t.Fatalf("error %q does not contain %q", msg, tt.wantErrSub)
				}
				if tt.wantStatus < 500 && len(s.put) != 0 {
					t.Fatal("store written on client error")
				}
				return
			}
			var got CreateResponse
			if err := json.Unmarshal([]byte(resp.Body), &got); err != nil {
				t.Fatal(err)
			}
			if got.ID != "id-1" || got.Upload.URL == "" || got.Upload.Fields["key"] != "photos/"+testUser+"/id-1" {
				t.Fatalf("unexpected response %+v", got)
			}
			if len(s.put) != 1 {
				t.Fatalf("want 1 stored item, got %d", len(s.put))
			}
			stored := s.put[0]
			if stored.UserID != testUser || stored.ID != "id-1" || stored.Status != photos.StatusPending || !stored.CreatedAt.Equal(fixedNow) || stored.ContentType != p.gotType {
				t.Fatalf("unexpected stored item %+v", stored)
			}
		})
	}
}

func TestList(t *testing.T) {
	taken := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	ready := []photos.Photo{
		{ID: "a", Lat: 1, Lng: 2, TakenAt: &taken, CreatedAt: fixedNow, Status: photos.StatusReady},
		{ID: "b", Lat: -3, Lng: 4, CreatedAt: fixedNow, Status: photos.StatusReady},
	}
	tests := []struct {
		name       string
		store      *fakeStore
		presigner  *fakePresigner
		wantStatus int
		wantIDs    []string
	}{
		{name: "two photos", store: &fakeStore{ready: ready}, wantStatus: http.StatusOK, wantIDs: []string{"a", "b"}},
		{name: "empty", store: &fakeStore{}, wantStatus: http.StatusOK, wantIDs: []string{}},
		{name: "store error", store: &fakeStore{listErr: errors.New("boom")}, wantStatus: http.StatusInternalServerError},
		{name: "presign error", store: &fakeStore{ready: ready}, presigner: &fakePresigner{getErr: errors.New("boom")}, wantStatus: http.StatusInternalServerError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := tt.presigner
			if p == nil {
				p = &fakePresigner{}
			}
			resp, err := newHandler(tt.store, p).Handle(context.Background(), authed("GET /photos", testUser))
			if err != nil {
				t.Fatal(err)
			}
			if tt.store.listUser != testUser {
				t.Fatalf("listed user %q, want %q", tt.store.listUser, testUser)
			}
			if resp.StatusCode != tt.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tt.wantStatus)
			}
			if tt.wantStatus != http.StatusOK {
				errMsg(t, resp.Body)
				return
			}
			// Decode generically to also check the "photos" array is never null.
			var raw map[string]json.RawMessage
			if err := json.Unmarshal([]byte(resp.Body), &raw); err != nil || string(raw["photos"]) == "null" {
				t.Fatalf("bad body %s", resp.Body)
			}
			var got ListResponse
			if err := json.Unmarshal([]byte(resp.Body), &got); err != nil {
				t.Fatal(err)
			}
			if len(got.Photos) != len(tt.wantIDs) {
				t.Fatalf("got %d photos, want %d", len(got.Photos), len(tt.wantIDs))
			}
			for i, ph := range got.Photos {
				if ph.ID != tt.wantIDs[i] || ph.ImageURL != "https://get.example/photos/"+testUser+"/"+ph.ID {
					t.Fatalf("photo %d = %+v", i, ph)
				}
			}
		})
	}
}

func TestListIsOwnerScoped(t *testing.T) {
	s := &fakeStore{ready: []photos.Photo{{ID: "a", Status: photos.StatusReady}}}
	resp, _ := newHandler(s, &fakePresigner{}).Handle(context.Background(), authed("GET /photos", "someone-else"))
	if resp.StatusCode != http.StatusOK || s.listUser != "someone-else" {
		t.Fatalf("status %d, listed user %q", resp.StatusCode, s.listUser)
	}
	var got ListResponse
	if err := json.Unmarshal([]byte(resp.Body), &got); err != nil || len(got.Photos) != 0 {
		t.Fatalf("other user saw photos: %s", resp.Body)
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
	for _, route := range []string{"POST /photos", "GET /photos"} {
		t.Run(route, func(t *testing.T) {
			s := &fakeStore{}
			req := events.APIGatewayV2HTTPRequest{RouteKey: route, Body: `{"lat":1,"lng":1,"contentType":"image/jpeg"}`}
			resp, err := newHandler(s, &fakePresigner{}).Handle(context.Background(), req)
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", resp.StatusCode)
			}
			errMsg(t, resp.Body)
			if len(s.put) != 0 || s.listUser != "" {
				t.Fatal("store touched without a user")
			}
		})
	}
}

func TestUnknownRoute(t *testing.T) {
	resp, _ := newHandler(&fakeStore{}, &fakePresigner{}).Handle(context.Background(), authed("DELETE /photos", testUser))
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	errMsg(t, resp.Body)
}

func TestDelete(t *testing.T) {
	const otherUser = "0a0a0a0a-2222-4b4b-8c8c-0123456789ab"
	tests := []struct {
		name        string
		user        string
		id          string
		store       *fakeStore
		objects     *fakeObjects
		wantStatus  int
		wantObject  bool // object delete attempted
		wantDeleted bool // record deleted
	}{
		{name: "ok", user: testUser, id: "p1", wantStatus: http.StatusNoContent, wantObject: true, wantDeleted: true},
		{name: "missing", user: testUser, id: "nope", wantStatus: http.StatusNotFound, wantObject: true},
		{name: "other user's photo", user: otherUser, id: "p1", wantStatus: http.StatusNotFound, wantObject: true},
		{name: "invalid id", user: testUser, id: "../p1", wantStatus: http.StatusNotFound},
		{name: "empty id", user: testUser, id: "", wantStatus: http.StatusNotFound},
		{name: "object delete fails keeps record", user: testUser, id: "p1", objects: &fakeObjects{err: errors.New("boom")}, wantStatus: http.StatusInternalServerError},
		{name: "store error", user: testUser, id: "p1", store: &fakeStore{deleteErr: errors.New("boom")}, wantStatus: http.StatusInternalServerError, wantObject: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s, o := tt.store, tt.objects
			if s == nil {
				s = &fakeStore{exists: map[string]bool{testUser + "/p1": true}}
			}
			if o == nil {
				o = &fakeObjects{}
			}
			h := newHandler(s, &fakePresigner{})
			h.Objects = o
			req := authed("DELETE /photos/{id}", tt.user)
			req.PathParameters = map[string]string{"id": tt.id}
			resp, err := h.Handle(context.Background(), req)
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", resp.StatusCode, tt.wantStatus, resp.Body)
			}
			if tt.wantStatus != http.StatusNoContent {
				errMsg(t, resp.Body)
			} else if resp.Body != "" {
				t.Fatalf("204 body = %q, want empty", resp.Body)
			}
			if got := len(o.deleted) == 1; got != tt.wantObject {
				t.Fatalf("object deleted = %v, want %v (%v)", got, tt.wantObject, o.deleted)
			}
			if tt.wantObject && o.deleted[0] != photos.ObjectKey(tt.user, tt.id) {
				t.Fatalf("deleted key %q, want caller-scoped %q", o.deleted[0], photos.ObjectKey(tt.user, tt.id))
			}
			if got := len(s.deleted) == 1; got != tt.wantDeleted {
				t.Fatalf("record deleted = %v, want %v", got, tt.wantDeleted)
			}
		})
	}
}
