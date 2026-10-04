package photos

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// Upload quotas and storage caps (trip photos only; the legacy /photos API is
// not metered).
//
// Usage lives in AppTable:
//
//	PK=USAGE#<userId>  SK=USAGE   day, dayCount: upload URLs issued on that UTC day
//	                              used, stored (see below)
//	PK=USAGE#ALL       SK=USAGE   used, stored, summed over all users
//	PK=USAGE#<userId>  SK=PENDING#<createdAt>#<tripId>#<photoId>
//	                              an outstanding reservation (bytes)
//
// "stored" is the size of ready photos. "used" is what the caps are checked
// against: stored plus a reservation of MaxUploadBytes for every upload URL
// that hasn't landed yet.
//
// Write budget (the table's write throughput is capped, so this matters):
// issuing an upload URL is one conditional UpdateItem on USAGE#ALL plus a
// 3-item transaction (photo, user usage, reservation) = 7 WRU; the upload
// landing is 3 single-item writes plus a 2-item transaction = 7 WRU. The
// per-user checks are exact (inside the transaction). The total is reserved
// with its own conditional write just before the transaction and given back
// if the transaction fails, so it can't be overshot either.
//
// Writes outside a transaction are ordered so that a crash part-way leaves
// usage over-counted (the safe direction for a cap), never under-counted.
//
// Reservations for uploads that never happen are released lazily: when a
// user hits a storage cap, their own reservations older than ReservationTTL
// (the 10-minute upload URL has long expired) are released and the request
// is retried once.

// Limits are the quotas checked before an upload URL is issued.
type Limits struct {
	DailyUploads int64 // upload URLs per user per UTC day
	UserBytes    int64 // stored + reserved bytes per user
	TotalBytes   int64 // stored + reserved bytes across all users
}

// ReservationTTL is how long an unused reservation is kept. It must exceed
// the presigned POST expiry (10 minutes) plus upload and event delivery time.
const ReservationTTL = time.Hour

// Quota errors. They are returned (wrapped) by PutPhoto; their text is the
// API error message.
var (
	ErrDailyLimit   = errors.New("daily upload limit reached")
	ErrUserStorage  = errors.New("storage limit reached")
	ErrTotalStorage = errors.New("service storage limit reached")
)

const (
	usageAllPK      = "USAGE#ALL"
	usageSK         = "USAGE"
	pendingSKPrefix = "PENDING#"
	// putAttempts bounds retries when a user's usage item changes between
	// being read and being written (e.g. parallel uploads).
	putAttempts = 4
)

func usagePK(userID string) string { return "USAGE#" + userID }

func pendingSK(p Photo) string {
	return pendingSKPrefix + p.CreatedAt.UTC().Format(orderLayout) + "#" + p.TripID + "#" + p.ID
}

// usage is a USAGE item.
type usage struct {
	Day      string `dynamodbav:"day"`
	DayCount int64  `dynamodbav:"dayCount"`
	Used     int64  `dynamodbav:"used"`
	Stored   int64  `dynamodbav:"stored"`
}

// reservation is a PENDING# item.
type reservation struct {
	SK      string `dynamodbav:"SK"`
	TripID  string `dynamodbav:"tripId"`
	PhotoID string `dynamodbav:"photoId"`
	Bytes   int64  `dynamodbav:"bytes"`
}

func num(n int64) types.AttributeValue {
	return &types.AttributeValueMemberN{Value: strconv.FormatInt(n, 10)}
}

func sv(s string) types.AttributeValue { return &types.AttributeValueMemberS{Value: s} }

// cancelCodes returns the per-item cancellation codes of a
// TransactionCanceledException (nil for any other error).
func cancelCodes(err error) []string {
	var tce *types.TransactionCanceledException
	if !errors.As(err, &tce) {
		return nil
	}
	out := make([]string, len(tce.CancellationReasons))
	for i, r := range tce.CancellationReasons {
		out[i] = aws.ToString(r.Code)
	}
	return out
}

func codeAt(codes []string, i int) string {
	if i < len(codes) {
		return codes[i]
	}
	return ""
}

// addUsage adds used/stored deltas to a USAGE item (creating it).
func (s *DynamoStore) addUsage(ctx context.Context, pk string, used, stored int64) error {
	_, err := s.Client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:                 &s.Table,
		Key:                       key(pk, usageSK),
		UpdateExpression:          aws.String("ADD #u :u, #st :st"),
		ExpressionAttributeNames:  map[string]string{"#u": "used", "#st": "stored"},
		ExpressionAttributeValues: map[string]types.AttributeValue{":u": num(used), ":st": num(stored)},
	})
	if err != nil {
		return fmt.Errorf("update usage %s: %w", pk, err)
	}
	return nil
}

// releasePending deletes a reservation item and reports whether it existed
// (false: already released or swapped by someone else).
func (s *DynamoStore) releasePending(ctx context.Context, userID, sk string) (bool, error) {
	_, err := s.Client.DeleteItem(ctx, &dynamodb.DeleteItemInput{
		TableName: &s.Table, Key: key(usagePK(userID), sk), ConditionExpression: aws.String(attributeExists),
	})
	if isConditionFailed(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("delete reservation: %w", err)
	}
	return true, nil
}

// giveBack subtracts bytes from the user's and the total usage. Errors are
// logged, not returned: the caller's main write already happened, and a
// missed give-back only over-counts.
func (s *DynamoStore) giveBack(ctx context.Context, userID string, used, stored int64) {
	for _, pk := range []string{usagePK(userID), usageAllPK} {
		if err := s.addUsage(ctx, pk, -used, -stored); err != nil {
			slog.ErrorContext(ctx, "usage give-back failed (usage over-counted)", "pk", pk, "used", used, "stored", stored, "err", err)
		}
	}
}

// PutPhoto creates a new pending photo record, counts the upload against the
// uploader's daily limit and reserves MaxUploadBytes against the user and
// total storage caps. It returns an error wrapping ErrDailyLimit,
// ErrUserStorage or ErrTotalStorage when a limit would be exceeded (nothing
// is kept then), and fails if the id already exists.
func (s *DynamoStore) PutPhoto(ctx context.Context, p Photo, lim Limits) error {
	const res = MaxUploadBytes
	switch {
	case lim.DailyUploads < 1:
		return ErrDailyLimit
	case lim.UserBytes < res:
		return ErrUserStorage
	case lim.TotalBytes < res:
		return ErrTotalStorage
	}
	p.Reserved = res
	photo, err := item(tripPK(p.TripID), photoSK(p.ID), "photo", p)
	if err != nil {
		return err
	}
	pending, err := item(usagePK(p.UploaderID), pendingSK(p), "reservation", reservation{
		SK: pendingSK(p), TripID: p.TripID, PhotoID: p.ID, Bytes: res,
	})
	if err != nil {
		return err
	}
	today := p.CreatedAt.UTC().Format(dateLayout)

	for attempt := 0; attempt < putAttempts; attempt++ {
		var u usage
		if err := s.getConsistent(ctx, usagePK(p.UploaderID), usageSK, &u); err != nil && !errors.Is(err, ErrNotFound) {
			return err
		}
		if u.Day == today && u.DayCount >= lim.DailyUploads {
			return fmt.Errorf("put photo: %w", ErrDailyLimit)
		}
		if u.Used > lim.UserBytes-res {
			return fmt.Errorf("put photo: %w", ErrUserStorage)
		}

		// Reserve against the total first; given back if the transaction fails.
		_, err := s.Client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
			TableName:                 &s.Table,
			Key:                       key(usageAllPK, usageSK),
			UpdateExpression:          aws.String("ADD #u :n"),
			ConditionExpression:       aws.String("attribute_not_exists(#u) OR #u <= :room"),
			ExpressionAttributeNames:  map[string]string{"#u": "used"},
			ExpressionAttributeValues: map[string]types.AttributeValue{":n": num(res), ":room": num(lim.TotalBytes - res)},
		})
		if isConditionFailed(err) {
			return fmt.Errorf("put photo: %w", ErrTotalStorage)
		}
		if err != nil {
			return fmt.Errorf("reserve total: %w", err)
		}

		_, err = s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
			TransactItems: []types.TransactWriteItem{
				{Put: &types.Put{TableName: &s.Table, Item: photo, ConditionExpression: aws.String(attributeAbsent)}},
				{Update: s.countUpload(p.UploaderID, u.Day == today, today, lim)},
				{Put: &types.Put{TableName: &s.Table, Item: pending}},
			},
		})
		if err == nil {
			return nil
		}
		if gerr := s.addUsage(ctx, usageAllPK, -res, 0); gerr != nil {
			slog.ErrorContext(ctx, "total reservation give-back failed (usage over-counted)", "err", gerr)
		}
		codes := cancelCodes(err)
		switch {
		case codeAt(codes, 0) == "ConditionalCheckFailed":
			return fmt.Errorf("put photo: id exists: %w", err)
		case codeAt(codes, 1) == "ConditionalCheckFailed" || codeAt(codes, 1) == "TransactionConflict":
			continue // usage changed since we read it: re-read and re-check
		}
		return fmt.Errorf("put photo: %w", err)
	}
	return fmt.Errorf("put photo: %w", errChanged)
}

// countUpload is the user usage update in PutPhoto's transaction: one more
// upload today and MaxUploadBytes more used, guarded by the limits and by
// the day the caller read (sameDay), so a stale read can't reset the count.
func (s *DynamoStore) countUpload(userID string, sameDay bool, today string, lim Limits) *types.Update {
	const res = MaxUploadBytes
	u := &types.Update{
		TableName:                &s.Table,
		Key:                      key(usagePK(userID), usageSK),
		ExpressionAttributeNames: map[string]string{"#d": "day", "#dc": "dayCount", "#u": "used"},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":today": sv(today), ":one": num(1), ":res": num(res), ":room": num(lim.UserBytes - res),
		},
	}
	if sameDay {
		u.UpdateExpression = aws.String("ADD #dc :one, #u :res")
		u.ConditionExpression = aws.String("#d = :today AND #dc < :max AND #u <= :room")
		u.ExpressionAttributeValues[":max"] = num(lim.DailyUploads)
	} else {
		u.UpdateExpression = aws.String("SET #d = :today, #dc = :one ADD #u :res")
		u.ConditionExpression = aws.String("(attribute_not_exists(#d) OR #d <> :today) AND (attribute_not_exists(#u) OR #u <= :room)")
	}
	return u
}

// errChanged means a record changed between being read and being written;
// the caller should re-read and retry.
var errChanged = errors.New("changed concurrently")

// DeletePhoto removes a photo record and, for a ready photo, its listing
// copy, then gives its bytes back to the uploader's and the total usage (its
// size if it was counted, else its outstanding reservation). p is the record
// as returned by GetPhoto. It returns ErrNotFound if a ready photo no longer
// exists, and an error (retryable) if a pending photo became ready or
// disappeared since it was read.
func (s *DynamoStore) DeletePhoto(ctx context.Context, p Photo) error {
	pk := tripPK(p.TripID)
	if p.Status == StatusReady {
		_, err := s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
			TransactItems: []types.TransactWriteItem{
				{Delete: &types.Delete{TableName: &s.Table, Key: key(pk, photoSK(p.ID)), ConditionExpression: aws.String(attributeExists)}},
				{Delete: &types.Delete{TableName: &s.Table, Key: key(pk, readySK(p))}},
			},
		})
		if isConditionFailed(err) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("delete photo: %w", err)
		}
		if p.Counted {
			s.giveBack(ctx, p.UploaderID, p.Size, p.Size)
		}
		return nil
	}
	_, err := s.Client.DeleteItem(ctx, &dynamodb.DeleteItemInput{
		TableName: &s.Table, Key: key(pk, photoSK(p.ID)),
		ConditionExpression:       aws.String("#s = :pending"),
		ExpressionAttributeNames:  map[string]string{"#s": "status"},
		ExpressionAttributeValues: map[string]types.AttributeValue{":pending": sv(StatusPending)},
	})
	if isConditionFailed(err) {
		return fmt.Errorf("delete pending photo: %w", errChanged)
	}
	if err != nil {
		return fmt.Errorf("delete photo: %w", err)
	}
	if p.Reserved > 0 {
		// Only if the reservation is still outstanding (not released as
		// stale, nor swapped by a racing MarkReady).
		released, err := s.releasePending(ctx, p.UploaderID, pendingSK(p))
		if err != nil {
			slog.ErrorContext(ctx, "reservation release failed (usage over-counted)", "id", p.ID, "err", err)
		} else if released {
			s.giveBack(ctx, p.UploaderID, p.Reserved, 0)
		}
	}
	return nil
}

// MarkReady flips a pending photo to "ready", records the object size, adds
// its listing copy and counts the size in the uploader's and the total usage
// (swapping out the photo's reservation). It returns ErrNotFound if no record
// exists for (tripID, id), and nil if the photo is already ready (S3 can
// deliver an event more than once).
//
// The usage writes come first and the photo transaction last, so a failure
// part-way (the processor retries) can only over-count.
func (s *DynamoStore) MarkReady(ctx context.Context, tripID, id string, size int64) error {
	var p Photo
	if err := s.get(ctx, tripPK(tripID), photoSK(id), &p); err != nil {
		return err
	}
	if p.Status == StatusReady {
		return nil
	}
	used := size
	if p.Reserved > 0 {
		released, err := s.releasePending(ctx, p.UploaderID, pendingSK(p))
		if err != nil {
			return fmt.Errorf("mark ready: %w", err)
		}
		if released {
			used -= p.Reserved // swap the reservation for the real size
		}
	}
	for _, pk := range []string{usagePK(p.UploaderID), usageAllPK} {
		if err := s.addUsage(ctx, pk, used, size); err != nil {
			return fmt.Errorf("mark ready: %w", err)
		}
	}

	p.Status, p.Size, p.Counted = StatusReady, size, true
	listing, err := item(tripPK(tripID), readySK(p), "readyPhoto", p)
	if err != nil {
		return err
	}
	_, err = s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
		TransactItems: []types.TransactWriteItem{
			{Update: &types.Update{
				TableName:                &s.Table,
				Key:                      key(tripPK(tripID), photoSK(id)),
				UpdateExpression:         aws.String("SET #s = :ready, #sz = :size, #ct = :true"),
				ConditionExpression:      aws.String("#s = :pending"),
				ExpressionAttributeNames: map[string]string{"#s": "status", "#sz": "size", "#ct": "counted"},
				ExpressionAttributeValues: map[string]types.AttributeValue{
					":ready":   sv(StatusReady),
					":pending": sv(StatusPending),
					":size":    num(size),
					":true":    &types.AttributeValueMemberBOOL{Value: true},
				},
			}},
			{Put: &types.Put{TableName: &s.Table, Item: listing}},
		},
	})
	if isConditionFailed(err) {
		// Deleted or marked ready since we read it: the processor's retry
		// re-reads the record and settles it.
		return fmt.Errorf("mark ready: %w", errChanged)
	}
	if err != nil {
		return fmt.Errorf("mark ready: %w", err)
	}
	return nil
}

// ReleaseStaleReservations releases userID's reservations created before
// cutoff (uploads that never landed) and returns how many it released. A
// reservation settled concurrently (its upload landed, or the photo was
// deleted) is skipped.
func (s *DynamoStore) ReleaseStaleReservations(ctx context.Context, userID string, cutoff time.Time) (int, error) {
	res, err := s.Client.Query(ctx, &dynamodb.QueryInput{
		TableName:              &s.Table,
		KeyConditionExpression: aws.String("PK = :pk AND SK BETWEEN :from AND :to"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":pk":   sv(usagePK(userID)),
			":from": sv(pendingSKPrefix),
			":to":   sv(pendingSKPrefix + cutoff.UTC().Format(orderLayout)),
		},
		Limit: aws.Int32(100),
	})
	if err != nil {
		return 0, fmt.Errorf("query reservations: %w", err)
	}
	var stale []reservation
	if err := attributevalue.UnmarshalListOfMaps(res.Items, &stale); err != nil {
		return 0, fmt.Errorf("unmarshal reservations: %w", err)
	}
	released := 0
	for _, r := range stale {
		ok, err := s.releasePending(ctx, userID, r.SK)
		if err != nil {
			return released, err
		}
		if ok {
			s.giveBack(ctx, userID, r.Bytes, 0)
			released++
		}
	}
	return released, nil
}

// getConsistent is get with a strongly consistent read.
func (s *DynamoStore) getConsistent(ctx context.Context, pk, sk string, out any) error {
	res, err := s.Client.GetItem(ctx, &dynamodb.GetItemInput{TableName: &s.Table, Key: key(pk, sk), ConsistentRead: aws.Bool(true)})
	if err != nil {
		return fmt.Errorf("get %s/%s: %w", pk, sk, err)
	}
	if res.Item == nil {
		return ErrNotFound
	}
	if err := attributevalue.UnmarshalMap(res.Item, out); err != nil {
		return fmt.Errorf("unmarshal %s/%s: %w", pk, sk, err)
	}
	return nil
}
