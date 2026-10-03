package photos

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// ErrNotFound is returned when a trip or photo record does not exist.
var ErrNotFound = errors.New("not found")

// DynamoStore keeps everything in one DynamoDB table keyed by generic "PK"
// and "SK" strings. Item shapes:
//
//	PK=TRIP#<tripId>  SK=META              the trip
//	PK=TRIP#<tripId>  SK=MEMBER#<userId>   someone in the trip
//	PK=TRIP#<tripId>  SK=PHOTO#<photoId>   a photo in the trip (pending or ready)
//	PK=TRIP#<tripId>  SK=READY#<order>#<photoId>
//	                                       listing copy of a ready photo
//	PK=USER#<userId>  SK=TRIP#<tripId>     "my trips" entry (copy of the trip)
//	PK=USAGE#...                           quota counters (see quota.go)
//
// Listing a trip's photos queries only the READY# range, so pending records
// are never read (or paid for) by a list, and the range is already in
// capture order (see ListOrder), which makes cursor pagination a plain
// DynamoDB page.
//
// The schema is deliberately loose: new attributes can be added to any item
// without a migration.
type DynamoStore struct {
	Client *dynamodb.Client
	Table  string
}

func tripPK(tripID string) string   { return "TRIP#" + tripID }
func userPK(userID string) string   { return "USER#" + userID }
func memberSK(userID string) string { return "MEMBER#" + userID }
func photoSK(photoID string) string { return "PHOTO#" + photoID }
func readySK(p Photo) string        { return readySKPrefix + ListOrder(p) + "#" + p.ID }

// orderLayout is a fixed-width UTC timestamp, so it sorts lexically.
const orderLayout = "2006-01-02T15:04:05.000000000Z"

// ListOrder is the sort key of a ready photo in its trip's listing: capture
// time (UTC); photos without one go last ("~" sorts after digits), by upload
// time. Ties are broken by id.
func ListOrder(p Photo) string {
	if p.TakenAt != nil {
		return p.TakenAt.UTC().Format(orderLayout)
	}
	return "~" + p.CreatedAt.UTC().Format(orderLayout)
}

// ErrInvalidCursor is returned for a list cursor this store didn't issue.
var ErrInvalidCursor = fmt.Errorf("%w: invalid cursor", ErrValidation)

// EncodeCursor turns the sort key of the last photo on a page into an opaque
// cursor.
func EncodeCursor(sk string) string { return base64.RawURLEncoding.EncodeToString([]byte(sk)) }

// DecodeCursor is the inverse of EncodeCursor; it returns ErrInvalidCursor
// for anything that isn't a listing sort key.
func DecodeCursor(c string) (string, error) {
	b, err := base64.RawURLEncoding.DecodeString(c)
	if err != nil || len(b) > 512 || !strings.HasPrefix(string(b), readySKPrefix) {
		return "", ErrInvalidCursor
	}
	return string(b), nil
}

const (
	metaSK          = "META"
	tripSKPrefix    = "TRIP#"
	readySKPrefix   = "READY#"
	attributeExists = "attribute_exists(PK)"
	attributeAbsent = "attribute_not_exists(PK)"
)

func key(pk, sk string) map[string]types.AttributeValue {
	return map[string]types.AttributeValue{
		"PK": &types.AttributeValueMemberS{Value: pk},
		"SK": &types.AttributeValueMemberS{Value: sk},
	}
}

// item marshals v and adds its PK, SK and a "type" attribute.
func item(pk, sk, typ string, v any) (map[string]types.AttributeValue, error) {
	m, err := attributevalue.MarshalMap(v)
	if err != nil {
		return nil, fmt.Errorf("marshal %s: %w", typ, err)
	}
	if m == nil {
		m = map[string]types.AttributeValue{}
	}
	for k, av := range key(pk, sk) {
		m[k] = av
	}
	m["type"] = &types.AttributeValueMemberS{Value: typ}
	return m, nil
}

// isConditionFailed reports whether a write (or any item of a transaction)
// failed its condition expression.
func isConditionFailed(err error) bool {
	var ccf *types.ConditionalCheckFailedException
	if errors.As(err, &ccf) {
		return true
	}
	var tce *types.TransactionCanceledException
	if errors.As(err, &tce) {
		for _, r := range tce.CancellationReasons {
			if aws.ToString(r.Code) == "ConditionalCheckFailed" {
				return true
			}
		}
	}
	return false
}

// CreateTrip writes the trip, makes its creator a member and adds it to the
// creator's trip list, all or nothing.
func (s *DynamoStore) CreateTrip(ctx context.Context, t Trip) error {
	meta, err := item(tripPK(t.ID), metaSK, "trip", t)
	if err != nil {
		return err
	}
	member, err := item(tripPK(t.ID), memberSK(t.CreatedBy), "member", struct {
		UserID string `dynamodbav:"userId"`
	}{t.CreatedBy})
	if err != nil {
		return err
	}
	mine, err := item(userPK(t.CreatedBy), tripSKPrefix+t.ID, "userTrip", t)
	if err != nil {
		return err
	}
	put := func(it map[string]types.AttributeValue) types.TransactWriteItem {
		return types.TransactWriteItem{Put: &types.Put{
			TableName: &s.Table, Item: it, ConditionExpression: aws.String(attributeAbsent),
		}}
	}
	_, err = s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
		TransactItems: []types.TransactWriteItem{put(meta), put(member), put(mine)},
	})
	if err != nil {
		return fmt.Errorf("create trip: %w", err)
	}
	return nil
}

// ListTrips returns the trips userID belongs to.
func (s *DynamoStore) ListTrips(ctx context.Context, userID string) ([]Trip, error) {
	var out []Trip
	err := s.query(ctx, userPK(userID), tripSKPrefix, func(items []map[string]types.AttributeValue) error {
		var batch []Trip
		if err := attributevalue.UnmarshalListOfMaps(items, &batch); err != nil {
			return fmt.Errorf("unmarshal trips: %w", err)
		}
		out = append(out, batch...)
		return nil
	})
	return out, err
}

// GetTrip returns the trip, or ErrNotFound.
func (s *DynamoStore) GetTrip(ctx context.Context, tripID string) (Trip, error) {
	var t Trip
	err := s.get(ctx, tripPK(tripID), metaSK, &t)
	return t, err
}

// IsMember reports whether userID is in the trip.
func (s *DynamoStore) IsMember(ctx context.Context, tripID, userID string) (bool, error) {
	out, err := s.Client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: &s.Table, Key: key(tripPK(tripID), memberSK(userID)),
		ProjectionExpression: aws.String("PK"),
	})
	if err != nil {
		return false, fmt.Errorf("get member: %w", err)
	}
	return out.Item != nil, nil
}

// GetPhoto returns one photo, or ErrNotFound.
func (s *DynamoStore) GetPhoto(ctx context.Context, tripID, id string) (Photo, error) {
	var p Photo
	err := s.get(ctx, tripPK(tripID), photoSK(id), &p)
	return p, err
}

// ListReadyPhotos returns up to limit of the trip's ready photos in
// ListOrder, starting after cursor ("" for the first page). next is "" when
// there are no further photos; a non-empty next can still lead to an empty
// last page. A malformed cursor returns ErrInvalidCursor.
func (s *DynamoStore) ListReadyPhotos(ctx context.Context, tripID string, limit int, cursor string) (out []Photo, next string, err error) {
	in := &dynamodb.QueryInput{
		TableName:              &s.Table,
		KeyConditionExpression: aws.String("PK = :pk AND begins_with(SK, :sk)"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":pk": &types.AttributeValueMemberS{Value: tripPK(tripID)},
			":sk": &types.AttributeValueMemberS{Value: readySKPrefix},
		},
		Limit: aws.Int32(int32(limit)),
	}
	if cursor != "" {
		sk, err := DecodeCursor(cursor)
		if err != nil {
			return nil, "", err
		}
		in.ExclusiveStartKey = key(tripPK(tripID), sk)
	}
	res, err := s.Client.Query(ctx, in)
	if err != nil {
		return nil, "", fmt.Errorf("query photos: %w", err)
	}
	if err := attributevalue.UnmarshalListOfMaps(res.Items, &out); err != nil {
		return nil, "", fmt.Errorf("unmarshal photos: %w", err)
	}
	if sk, ok := res.LastEvaluatedKey["SK"].(*types.AttributeValueMemberS); ok {
		next = EncodeCursor(sk.Value)
	}
	return out, next, nil
}

// errChanged means a photo changed between being read and being written; the
// caller should re-read and retry.
var errChanged = errors.New("photo changed concurrently")

// DeletePhoto removes a photo record and, for a ready photo, its listing
// copy, and gives its bytes back to the uploader's and the total usage
// counters (its size if it was counted, else its outstanding reservation).
// p is the record as returned by GetPhoto. It returns ErrNotFound if a ready
// photo no longer exists, and an error (retryable) if a pending photo became
// ready or disappeared since it was read.
func (s *DynamoStore) DeletePhoto(ctx context.Context, p Photo) error {
	pk := tripPK(p.TripID)
	if p.Status == StatusReady {
		items := []types.TransactWriteItem{
			{Delete: &types.Delete{TableName: &s.Table, Key: key(pk, photoSK(p.ID)), ConditionExpression: aws.String(attributeExists)}},
			{Delete: &types.Delete{TableName: &s.Table, Key: key(pk, readySK(p))}},
		}
		if p.Counted {
			items = append(items, s.addBytes(usagePK(p.UploaderID), -p.Size, -p.Size), s.addBytes(usageAllPK, -p.Size, -p.Size))
		}
		_, err := s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{TransactItems: items})
		if isConditionFailed(err) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("delete photo: %w", err)
		}
		return nil
	}
	cond := aws.String("#s = :pending")
	names := map[string]string{"#s": "status"}
	vals := map[string]types.AttributeValue{":pending": &types.AttributeValueMemberS{Value: StatusPending}}
	if p.Reserved > 0 {
		// Release the reservation with the record, unless it was already
		// released as stale (then just delete the record, below).
		_, err := s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
			TransactItems: []types.TransactWriteItem{
				{Delete: &types.Delete{
					TableName: &s.Table, Key: key(pk, photoSK(p.ID)),
					ConditionExpression: cond, ExpressionAttributeNames: names, ExpressionAttributeValues: vals,
				}},
				{Delete: &types.Delete{TableName: &s.Table, Key: key(usagePK(p.UploaderID), pendingSK(p)), ConditionExpression: aws.String(attributeExists)}},
				s.addBytes(usagePK(p.UploaderID), -p.Reserved, 0),
				s.addBytes(usageAllPK, -p.Reserved, 0),
			},
		})
		reasons := cancelled(err)
		switch {
		case err == nil:
			return nil
		case failedAt(reasons, 0):
			return fmt.Errorf("delete pending photo: %w", errChanged)
		case !failedAt(reasons, 1):
			return fmt.Errorf("delete photo: %w", err)
		}
	}
	_, err := s.Client.DeleteItem(ctx, &dynamodb.DeleteItemInput{
		TableName: &s.Table, Key: key(pk, photoSK(p.ID)),
		ConditionExpression: cond, ExpressionAttributeNames: names, ExpressionAttributeValues: vals,
	})
	if isConditionFailed(err) {
		return fmt.Errorf("delete pending photo: %w", errChanged)
	}
	if err != nil {
		return fmt.Errorf("delete photo: %w", err)
	}
	return nil
}

// MarkReady flips a pending photo to "ready", records the object size, adds
// its listing copy and counts the size in the uploader's and the total usage
// (swapping out the photo's reservation), atomically. It returns ErrNotFound
// if no record exists for (tripID, id), and nil if the photo is already
// ready (S3 can deliver an event more than once).
func (s *DynamoStore) MarkReady(ctx context.Context, tripID, id string, size int64) error {
	var p Photo
	if err := s.get(ctx, tripPK(tripID), photoSK(id), &p); err != nil {
		return err
	}
	if p.Status == StatusReady {
		return nil
	}
	release := p.Reserved > 0
	err := s.markReady(ctx, p, size, release)
	if reasons := cancelled(err); release && failedAt(reasons, 2) && !failedAt(reasons, 0) {
		// The reservation was released as stale before the upload landed:
		// count the size without releasing anything.
		err = s.markReady(ctx, p, size, false)
	}
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

// markReady writes the ready transition. With release, item 2 deletes the
// photo's reservation (failing if it's gone) and the counters swap the
// reservation for the size; without, the size is simply added.
func (s *DynamoStore) markReady(ctx context.Context, p Photo, size int64, release bool) error {
	p.Status, p.Size, p.Counted = StatusReady, size, true
	listing, err := item(tripPK(p.TripID), readySK(p), "readyPhoto", p)
	if err != nil {
		return err
	}
	items := []types.TransactWriteItem{
		{Update: &types.Update{
			TableName:                &s.Table,
			Key:                      key(tripPK(p.TripID), photoSK(p.ID)),
			UpdateExpression:         aws.String("SET #s = :ready, #sz = :size, #ct = :true"),
			ConditionExpression:      aws.String("#s = :pending"),
			ExpressionAttributeNames: map[string]string{"#s": "status", "#sz": "size", "#ct": "counted"},
			ExpressionAttributeValues: map[string]types.AttributeValue{
				":ready":   &types.AttributeValueMemberS{Value: StatusReady},
				":pending": &types.AttributeValueMemberS{Value: StatusPending},
				":size":    num(size),
				":true":    &types.AttributeValueMemberBOOL{Value: true},
			},
		}},
		{Put: &types.Put{TableName: &s.Table, Item: listing}},
	}
	used := size
	if release {
		items = append(items, types.TransactWriteItem{Delete: &types.Delete{
			TableName: &s.Table, Key: key(usagePK(p.UploaderID), pendingSK(p)), ConditionExpression: aws.String(attributeExists),
		}})
		used -= p.Reserved
	}
	items = append(items, s.addBytes(usagePK(p.UploaderID), used, size), s.addBytes(usageAllPK, used, size))
	_, err = s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{TransactItems: items})
	return err
}

func (s *DynamoStore) get(ctx context.Context, pk, sk string, out any) error {
	res, err := s.Client.GetItem(ctx, &dynamodb.GetItemInput{TableName: &s.Table, Key: key(pk, sk)})
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

// query pages through all items under pk whose SK starts with skPrefix.
func (s *DynamoStore) query(ctx context.Context, pk, skPrefix string, each func([]map[string]types.AttributeValue) error) error {
	in := &dynamodb.QueryInput{
		TableName:              &s.Table,
		KeyConditionExpression: aws.String("PK = :pk AND begins_with(SK, :sk)"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":pk": &types.AttributeValueMemberS{Value: pk},
			":sk": &types.AttributeValueMemberS{Value: skPrefix},
		},
	}
	p := dynamodb.NewQueryPaginator(s.Client, in)
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return fmt.Errorf("query %s: %w", pk, err)
		}
		if err := each(page.Items); err != nil {
			return err
		}
	}
	return nil
}
