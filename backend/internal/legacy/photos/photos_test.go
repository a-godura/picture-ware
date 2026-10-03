package photos

import (
	"errors"
	"testing"
	"time"
)

func ptr(f float64) *float64 { return &f }

func TestCreateRequestValidate(t *testing.T) {
	tests := []struct {
		name        string
		req         CreateRequest
		wantErr     bool
		wantTakenAt *time.Time
	}{
		{name: "valid jpeg", req: CreateRequest{Lat: ptr(37.77), Lng: ptr(-122.42), ContentType: "image/jpeg"}},
		{name: "valid heic boundaries", req: CreateRequest{Lat: ptr(-90), Lng: ptr(180), ContentType: "image/heic"}},
		{name: "valid zero coords", req: CreateRequest{Lat: ptr(0), Lng: ptr(0), ContentType: "image/jpeg"}},
		{
			name:        "valid takenAt",
			req:         CreateRequest{Lat: ptr(1), Lng: ptr(2), ContentType: "image/jpeg", TakenAt: "2026-09-01T10:00:00Z"},
			wantTakenAt: func() *time.Time { t := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC); return &t }(),
		},
		{name: "missing lat", req: CreateRequest{Lng: ptr(2), ContentType: "image/jpeg"}, wantErr: true},
		{name: "missing lng", req: CreateRequest{Lat: ptr(2), ContentType: "image/jpeg"}, wantErr: true},
		{name: "lat too high", req: CreateRequest{Lat: ptr(90.1), Lng: ptr(0), ContentType: "image/jpeg"}, wantErr: true},
		{name: "lat too low", req: CreateRequest{Lat: ptr(-90.1), Lng: ptr(0), ContentType: "image/jpeg"}, wantErr: true},
		{name: "lng too high", req: CreateRequest{Lat: ptr(0), Lng: ptr(180.1), ContentType: "image/jpeg"}, wantErr: true},
		{name: "lng too low", req: CreateRequest{Lat: ptr(0), Lng: ptr(-180.1), ContentType: "image/jpeg"}, wantErr: true},
		{name: "png not allowed", req: CreateRequest{Lat: ptr(0), Lng: ptr(0), ContentType: "image/png"}, wantErr: true},
		{name: "missing content type", req: CreateRequest{Lat: ptr(0), Lng: ptr(0)}, wantErr: true},
		{name: "bad takenAt", req: CreateRequest{Lat: ptr(0), Lng: ptr(0), ContentType: "image/jpeg", TakenAt: "yesterday"}, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := tt.req.Validate()
			if tt.wantErr {
				if !errors.Is(err, ErrValidation) {
					t.Fatalf("want ErrValidation, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			switch {
			case tt.wantTakenAt == nil && got != nil:
				t.Fatalf("want nil takenAt, got %v", got)
			case tt.wantTakenAt != nil && (got == nil || !got.Equal(*tt.wantTakenAt)):
				t.Fatalf("takenAt = %v, want %v", got, tt.wantTakenAt)
			}
		})
	}
}

func TestObjectKeyRoundTrip(t *testing.T) {
	const user, id = "8f0b2c1e-1111-4a5b-9c3d-abcdef012345", "6f1c0e8e-5d0b-4b8a-9f1e-2a3b4c5d6e7f"
	key := ObjectKey(user, id)
	if key != "photos/"+user+"/"+id {
		t.Fatalf("key = %q", key)
	}
	u, i, ok := ParseObjectKey(key)
	if !ok || u != user || i != id {
		t.Fatalf("ParseObjectKey(%q) = %q, %q, %v", key, u, i, ok)
	}
}

func TestParseObjectKeyRejects(t *testing.T) {
	for _, key := range []string{"", "photos/", "photos/id", "photos/u/", "photos//id", "photos/u/a/b", "other/u/id", "photos/../id", "photos/u u/id"} {
		if u, i, ok := ParseObjectKey(key); ok {
			t.Errorf("ParseObjectKey(%q) = %q, %q, true", key, u, i)
		}
	}
}
