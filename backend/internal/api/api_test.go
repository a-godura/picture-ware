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

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

type fakeStore struct {
	put     []photos.Photo
	ready   []photos.Photo
	putErr  error
	listErr error
}

func (f *fakeStore) Put(_ context.Context, p photos.Photo) error {
	if f.putErr != nil {
		return f.putErr
	}
	f.put = append(f.put, p)
	return nil
}

func (f *fakeStore) ListReady(context.Context) ([]photos.Photo, error) { return f.ready, f.listErr }

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

func newHandler(s *fakeStore, p *fakePresigner) *Handler {
	return &Handler{Store: s, Presigner: p, NewID: func() string { return "id-1" }, Now: func() time.Time { return fixedNow }}
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
			resp, err := newHandler(s, p).Handle(context.Background(), events.APIGatewayV2HTTPRequest{
				RouteKey: "POST /photos", Body: body, IsBase64Encoded: tt.b64,
			})
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
			if got.ID != "id-1" || got.Upload.URL == "" || got.Upload.Fields["key"] != "photos/id-1" {
				t.Fatalf("unexpected response %+v", got)
			}
			if len(s.put) != 1 {
				t.Fatalf("want 1 stored item, got %d", len(s.put))
			}
			stored := s.put[0]
			if stored.Status != photos.StatusPending || !stored.CreatedAt.Equal(fixedNow) || stored.ContentType != p.gotType {
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
			resp, err := newHandler(tt.store, p).Handle(context.Background(), events.APIGatewayV2HTTPRequest{RouteKey: "GET /photos"})
			if err != nil {
				t.Fatal(err)
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
				if ph.ID != tt.wantIDs[i] || ph.ImageURL != "https://get.example/photos/"+ph.ID {
					t.Fatalf("photo %d = %+v", i, ph)
				}
			}
		})
	}
}

func TestUnknownRoute(t *testing.T) {
	resp, _ := newHandler(&fakeStore{}, &fakePresigner{}).Handle(context.Background(), events.APIGatewayV2HTTPRequest{RouteKey: "DELETE /photos"})
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	errMsg(t, resp.Body)
}
