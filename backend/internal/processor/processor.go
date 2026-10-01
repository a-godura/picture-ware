// Package processor handles S3 ObjectCreated events for uploaded photos.
package processor

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"strings"

	"github.com/aws/aws-lambda-go/events"

	"github.com/a-godura/picture-ware/backend/internal/photos"
)

// Store is the subset of photo persistence the processor needs.
type Store interface {
	MarkReady(ctx context.Context, id string, size int64) error
}

// Handler marks photo records ready once their object lands in S3.
type Handler struct {
	Store Store
}

// Handle processes every record in an S3 event. Objects with no matching
// record (or outside photos/) are logged and skipped; store failures are
// returned so Lambda retries the async invocation.
func (h *Handler) Handle(ctx context.Context, ev events.S3Event) error {
	var errs []error
	for _, r := range ev.Records {
		key, err := url.QueryUnescape(r.S3.Object.Key)
		if err != nil {
			slog.WarnContext(ctx, "skipping undecodable key", "key", r.S3.Object.Key)
			continue
		}
		id, ok := idFromKey(key)
		if !ok {
			slog.WarnContext(ctx, "skipping unexpected key", "key", key)
			continue
		}
		err = h.Store.MarkReady(ctx, id, r.S3.Object.Size)
		switch {
		case errors.Is(err, photos.ErrNotFound):
			slog.WarnContext(ctx, "no record for uploaded object", "id", id)
		case err != nil:
			errs = append(errs, fmt.Errorf("mark %s ready: %w", id, err))
		default:
			slog.InfoContext(ctx, "photo ready", "id", id, "size", r.S3.Object.Size)
		}
	}
	return errors.Join(errs...)
}

func idFromKey(key string) (string, bool) {
	id, ok := strings.CutPrefix(key, photos.KeyPrefix)
	if !ok || id == "" || strings.Contains(id, "/") {
		return "", false
	}
	return id, true
}
