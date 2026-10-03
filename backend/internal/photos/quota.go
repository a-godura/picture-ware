package photos

import (
	"context"
	"errors"
	"fmt"
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
// Usage lives in AppTable as atomic counters:
//
//	PK=USAGE#<userId>  SK=DAY#<yyyy-mm-dd>  count: upload URLs issued that UTC day (expires via ttl)
//	PK=USAGE#<userId>  SK=BYTES             used, stored (see below)
//	PK=USAGE#ALL       SK=BYTES             used, stored, summed over all users
//	PK=USAGE#<userId>  SK=PENDING#<createdAt>#<tripId>#<photoId>
//	                                        an outstanding reservation (bytes)
//
// "stored" is the size of the user's ready photos. "used" is what quotas are
// checked against: stored plus a reservation of MaxUploadBytes for every
// upload URL that hasn't landed yet. Issuing an upload URL reserves (in the
// same transaction that creates the pending photo, conditional on the
// counters), so concurrent requests cannot overshoot a cap. When the upload
// lands, the reservation is swapped for the real object size; deleting a
// photo gives back its size (or its reservation, if it never landed).
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
	bytesSK         = "BYTES"
	daySKPrefix     = "DAY#"
	pendingSKPrefix = "PENDING#"
	dayTTL          = 48 * time.Hour
)

func usagePK(userID string) string { return "USAGE#" + userID }

func daySK(t time.Time) string { return daySKPrefix + t.UTC().Format(dateLayout) }

func pendingSK(p Photo) string {
	return pendingSKPrefix + p.CreatedAt.UTC().Format(orderLayout) + "#" + p.TripID + "#" + p.ID
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

// addBytes adds used/stored deltas to a BYTES counter (creating it).
func (s *DynamoStore) addBytes(pk string, used, stored int64) types.TransactWriteItem {
	return types.TransactWriteItem{Update: &types.Update{
		TableName:                &s.Table,
		Key:                      key(pk, bytesSK),
		UpdateExpression:         aws.String("ADD #u :u, #st :st"),
		ExpressionAttributeNames: map[string]string{"#u": "used", "#st": "stored"},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":u": num(used), ":st": num(stored),
		},
	}}
}

// reserveBytes adds n to "used" only if that keeps it within limit.
func (s *DynamoStore) reserveBytes(pk string, n, limit int64) types.TransactWriteItem {
	return types.TransactWriteItem{Update: &types.Update{
		TableName:                &s.Table,
		Key:                      key(pk, bytesSK),
		UpdateExpression:         aws.String("ADD #u :n"),
		ConditionExpression:      aws.String("attribute_not_exists(#u) OR #u <= :room"),
		ExpressionAttributeNames: map[string]string{"#u": "used"},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":n": num(n), ":room": num(limit - n),
		},
	}}
}

// cancelled returns, for a TransactionCanceledException, which items failed
// their condition (nil for any other error).
func cancelled(err error) []bool {
	var tce *types.TransactionCanceledException
	if !errors.As(err, &tce) {
		return nil
	}
	out := make([]bool, len(tce.CancellationReasons))
	for i, r := range tce.CancellationReasons {
		out[i] = aws.ToString(r.Code) == "ConditionalCheckFailed"
	}
	return out
}

func failedAt(reasons []bool, i int) bool { return i < len(reasons) && reasons[i] }

// PutPhoto creates a new pending photo record and, atomically with it,
// counts the upload against the uploader's daily limit and reserves
// MaxUploadBytes against the user and total storage caps. It returns an
// error wrapping ErrDailyLimit, ErrUserStorage or ErrTotalStorage when a
// limit would be exceeded (nothing is written then), and fails if the id
// already exists.
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
	day := p.CreatedAt.UTC().Truncate(24 * time.Hour)
	_, err = s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
		TransactItems: []types.TransactWriteItem{
			{Put: &types.Put{TableName: &s.Table, Item: photo, ConditionExpression: aws.String(attributeAbsent)}},
			{Update: &types.Update{
				TableName:                &s.Table,
				Key:                      key(usagePK(p.UploaderID), daySK(p.CreatedAt)),
				UpdateExpression:         aws.String("ADD #c :one SET #ttl = :ttl"),
				ConditionExpression:      aws.String("attribute_not_exists(#c) OR #c < :max"),
				ExpressionAttributeNames: map[string]string{"#c": "count", "#ttl": "ttl"},
				ExpressionAttributeValues: map[string]types.AttributeValue{
					":one": num(1), ":max": num(lim.DailyUploads), ":ttl": num(day.Add(dayTTL).Unix()),
				},
			}},
			s.reserveBytes(usagePK(p.UploaderID), res, lim.UserBytes),
			s.reserveBytes(usageAllPK, res, lim.TotalBytes),
			{Put: &types.Put{TableName: &s.Table, Item: pending}},
		},
	})
	reasons := cancelled(err)
	switch {
	case err == nil:
		return nil
	case failedAt(reasons, 1):
		return fmt.Errorf("put photo: %w", ErrDailyLimit)
	case failedAt(reasons, 2):
		return fmt.Errorf("put photo: %w", ErrUserStorage)
	case failedAt(reasons, 3):
		return fmt.Errorf("put photo: %w", ErrTotalStorage)
	}
	return fmt.Errorf("put photo: %w", err)
}

// ReleaseStaleReservations releases userID's reservations created before
// cutoff (uploads that never landed) and returns how many it released. A
// reservation that is settled concurrently (its upload landed, or the photo
// was deleted) is skipped.
func (s *DynamoStore) ReleaseStaleReservations(ctx context.Context, userID string, cutoff time.Time) (int, error) {
	res, err := s.Client.Query(ctx, &dynamodb.QueryInput{
		TableName:              &s.Table,
		KeyConditionExpression: aws.String("PK = :pk AND SK BETWEEN :from AND :to"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":pk":   &types.AttributeValueMemberS{Value: usagePK(userID)},
			":from": &types.AttributeValueMemberS{Value: pendingSKPrefix},
			":to":   &types.AttributeValueMemberS{Value: pendingSKPrefix + cutoff.UTC().Format(orderLayout)},
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
		_, err := s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
			TransactItems: []types.TransactWriteItem{
				{Delete: &types.Delete{TableName: &s.Table, Key: key(usagePK(userID), r.SK), ConditionExpression: aws.String(attributeExists)}},
				s.addBytes(usagePK(userID), -r.Bytes, 0),
				s.addBytes(usageAllPK, -r.Bytes, 0),
			},
		})
		if isConditionFailed(err) {
			continue
		}
		if err != nil {
			return released, fmt.Errorf("release reservation: %w", err)
		}
		released++
	}
	return released, nil
}
