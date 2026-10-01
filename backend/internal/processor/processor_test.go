package processor

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

type call struct {
	user string
	id   string
	size int64
}

type fakeStore struct {
	calls []call
	errs  map[string]error
}

func (f *fakeStore) MarkReady(_ context.Context, userID, id string, size int64) error {
	f.calls = append(f.calls, call{userID, id, size})
	return f.errs[id]
}

func record(key string, size int64) events.S3EventRecord {
	return events.S3EventRecord{S3: events.S3Entity{Object: events.S3Object{Key: key, Size: size}}}
}

func TestHandle(t *testing.T) {
	tests := []struct {
		name      string
		records   []events.S3EventRecord
		errs      map[string]error
		wantCalls []call
		wantErr   bool
	}{
		{name: "single photo", records: []events.S3EventRecord{record("photos/u1/abc", 1234)}, wantCalls: []call{{"u1", "abc", 1234}}},
		{name: "url-encoded key", records: []events.S3EventRecord{record("photos/u1/a%2Bb", 1)}, wantCalls: []call{{"u1", "a+b", 1}}},
		{
			name:      "multiple users",
			records:   []events.S3EventRecord{record("photos/u1/a", 1), record("photos/u2/b", 2)},
			wantCalls: []call{{"u1", "a", 1}, {"u2", "b", 2}},
		},
		{name: "wrong prefix skipped", records: []events.S3EventRecord{record("other/u1/a", 1)}},
		{name: "legacy key without user skipped", records: []events.S3EventRecord{record("photos/a", 1)}},
		{name: "too deep skipped", records: []events.S3EventRecord{record("photos/u1/a/b", 1)}},
		{name: "empty id skipped", records: []events.S3EventRecord{record("photos/u1/", 1)}},
		{name: "empty user skipped", records: []events.S3EventRecord{record("photos//a", 1)}},
		{name: "invalid user skipped", records: []events.S3EventRecord{record("photos/u.1/a", 1)}},
		{name: "bad escape skipped", records: []events.S3EventRecord{record("photos/u1/%zz", 1)}},
		{
			name:      "unknown id is not an error",
			records:   []events.S3EventRecord{record("photos/u1/ghost", 1)},
			errs:      map[string]error{"ghost": photos.ErrNotFound},
			wantCalls: []call{{"u1", "ghost", 1}},
		},
		{
			name:      "store failure returned, other records still processed",
			records:   []events.S3EventRecord{record("photos/u1/bad", 1), record("photos/u1/good", 2)},
			errs:      map[string]error{"bad": errors.New("throttled")},
			wantCalls: []call{{"u1", "bad", 1}, {"u1", "good", 2}},
			wantErr:   true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &fakeStore{errs: tt.errs}
			err := (&Handler{Store: s}).Handle(context.Background(), events.S3Event{Records: tt.records})
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if len(s.calls) != len(tt.wantCalls) {
				t.Fatalf("calls = %v, want %v", s.calls, tt.wantCalls)
			}
			for i := range s.calls {
				if s.calls[i] != tt.wantCalls[i] {
					t.Fatalf("calls = %v, want %v", s.calls, tt.wantCalls)
				}
			}
		})
	}
}
