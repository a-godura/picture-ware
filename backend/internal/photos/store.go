package photos

import (
	"context"
	"errors"
	"fmt"
	"strconv"

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
//	PK=TRIP#<tripId>  SK=PHOTO#<photoId>   a photo in the trip
//	PK=USER#<userId>  SK=TRIP#<tripId>     "my trips" entry (copy of the trip)
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

const (
	metaSK          = "META"
	tripSKPrefix    = "TRIP#"
	photoSKPrefix   = "PHOTO#"
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

func isConditionFailed(err error) bool {
	var ccf *types.ConditionalCheckFailedException
	return errors.As(err, &ccf)
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
	err := s.query(ctx, userPK(userID), tripSKPrefix, "", func(items []map[string]types.AttributeValue) error {
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

// PutPhoto creates a new photo record. It fails if the id already exists.
func (s *DynamoStore) PutPhoto(ctx context.Context, p Photo) error {
	it, err := item(tripPK(p.TripID), photoSK(p.ID), "photo", p)
	if err != nil {
		return err
	}
	_, err = s.Client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: &s.Table, Item: it, ConditionExpression: aws.String(attributeAbsent),
	})
	if err != nil {
		return fmt.Errorf("put photo: %w", err)
	}
	return nil
}

// GetPhoto returns one photo, or ErrNotFound.
func (s *DynamoStore) GetPhoto(ctx context.Context, tripID, id string) (Photo, error) {
	var p Photo
	err := s.get(ctx, tripPK(tripID), photoSK(id), &p)
	return p, err
}

// ListReadyPhotos returns the trip's photos whose status is "ready".
func (s *DynamoStore) ListReadyPhotos(ctx context.Context, tripID string) ([]Photo, error) {
	var out []Photo
	err := s.query(ctx, tripPK(tripID), photoSKPrefix, StatusReady, func(items []map[string]types.AttributeValue) error {
		var batch []Photo
		if err := attributevalue.UnmarshalListOfMaps(items, &batch); err != nil {
			return fmt.Errorf("unmarshal photos: %w", err)
		}
		out = append(out, batch...)
		return nil
	})
	return out, err
}

// DeletePhoto removes a photo record. It returns ErrNotFound if it doesn't exist.
func (s *DynamoStore) DeletePhoto(ctx context.Context, tripID, id string) error {
	_, err := s.Client.DeleteItem(ctx, &dynamodb.DeleteItemInput{
		TableName: &s.Table, Key: key(tripPK(tripID), photoSK(id)),
		ConditionExpression: aws.String(attributeExists),
	})
	if isConditionFailed(err) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("delete photo: %w", err)
	}
	return nil
}

// MarkReady flips an existing photo to "ready" and records the object size.
// It returns ErrNotFound if no record exists for (tripID, id).
func (s *DynamoStore) MarkReady(ctx context.Context, tripID, id string, size int64) error {
	_, err := s.Client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:                &s.Table,
		Key:                      key(tripPK(tripID), photoSK(id)),
		UpdateExpression:         aws.String("SET #s = :ready, #sz = :size"),
		ConditionExpression:      aws.String(attributeExists),
		ExpressionAttributeNames: map[string]string{"#s": "status", "#sz": "size"},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":ready": &types.AttributeValueMemberS{Value: StatusReady},
			":size":  &types.AttributeValueMemberN{Value: strconv.FormatInt(size, 10)},
		},
	})
	if isConditionFailed(err) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("mark ready: %w", err)
	}
	return nil
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

// query pages through items under pk whose SK starts with skPrefix, optionally
// keeping only those with the given status.
func (s *DynamoStore) query(ctx context.Context, pk, skPrefix, status string, each func([]map[string]types.AttributeValue) error) error {
	in := &dynamodb.QueryInput{
		TableName:              &s.Table,
		KeyConditionExpression: aws.String("PK = :pk AND begins_with(SK, :sk)"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":pk": &types.AttributeValueMemberS{Value: pk},
			":sk": &types.AttributeValueMemberS{Value: skPrefix},
		},
	}
	if status != "" {
		in.FilterExpression = aws.String("#s = :status")
		in.ExpressionAttributeNames = map[string]string{"#s": "status"}
		in.ExpressionAttributeValues[":status"] = &types.AttributeValueMemberS{Value: status}
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
