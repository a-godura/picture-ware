package processor

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

type call struct {
	id   string
	size int64
}

type fakeStore struct {
	calls []call
	errs  map[string]error
}

func (f *fakeStore) MarkReady(_ context.Context, id string, size int64) error {
	f.calls = append(f.calls, call{id, size})
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
		{name: "single photo", records: []events.S3EventRecord{record("photos/abc", 1234)}, wantCalls: []call{{"abc", 1234}}},
		{name: "url-encoded key", records: []events.S3EventRecord{record("photos/a%2Bb", 1)}, wantCalls: []call{{"a+b", 1}}},
		{name: "multiple", records: []events.S3EventRecord{record("photos/a", 1), record("photos/b", 2)}, wantCalls: []call{{"a", 1}, {"b", 2}}},
		{name: "wrong prefix skipped", records: []events.S3EventRecord{record("other/a", 1)}},
		{name: "nested key skipped", records: []events.S3EventRecord{record("photos/a/b", 1)}},
		{name: "empty id skipped", records: []events.S3EventRecord{record("photos/", 1)}},
		{name: "bad escape skipped", records: []events.S3EventRecord{record("photos/%zz", 1)}},
		{
			name:      "unknown id is not an error",
			records:   []events.S3EventRecord{record("photos/ghost", 1)},
			errs:      map[string]error{"ghost": photos.ErrNotFound},
			wantCalls: []call{{"ghost", 1}},
		},
		{
			name:      "store failure returned, other records still processed",
			records:   []events.S3EventRecord{record("photos/bad", 1), record("photos/good", 2)},
			errs:      map[string]error{"bad": errors.New("throttled")},
			wantCalls: []call{{"bad", 1}, {"good", 2}},
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
