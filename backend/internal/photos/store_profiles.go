package photos

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

const profileSK = "PROFILE"

// GetProfile returns the user's profile; a user who never set one gets an
// empty profile (not an error).
func (s *DynamoStore) GetProfile(ctx context.Context, userID string) (Profile, error) {
	p := Profile{UserID: userID}
	err := s.get(ctx, userPK(userID), profileSK, &p)
	if errors.Is(err, ErrNotFound) {
		return Profile{UserID: userID}, nil
	}
	return p, err
}

// PutProfile stores the user's profile (USER#<sub>/PROFILE).
func (s *DynamoStore) PutProfile(ctx context.Context, p Profile) error {
	it, err := item(userPK(p.UserID), profileSK, "profile", p)
	if err != nil {
		return err
	}
	if _, err := s.Client.PutItem(ctx, &dynamodb.PutItemInput{TableName: &s.Table, Item: it}); err != nil {
		return fmt.Errorf("put profile: %w", err)
	}
	return nil
}

// batchGetMax is DynamoDB's BatchGetItem limit.
const batchGetMax = 100

// DisplayNames returns the display names of the given users that have one
// (users without a profile or name are simply absent).
func (s *DynamoStore) DisplayNames(ctx context.Context, userIDs []string) (map[string]string, error) {
	out := make(map[string]string, len(userIDs))
	for start := 0; start < len(userIDs); start += batchGetMax {
		keys := make([]map[string]types.AttributeValue, 0, batchGetMax)
		for _, id := range userIDs[start:min(start+batchGetMax, len(userIDs))] {
			keys = append(keys, key(userPK(id), profileSK))
		}
		req := map[string]types.KeysAndAttributes{s.Table: {
			Keys:                 keys,
			ProjectionExpression: aws.String("userId, displayName"),
		}}
		// Retry unprocessed keys (throttling) a few times, then give up.
		for attempt := 0; len(req) > 0; attempt++ {
			if attempt == 5 {
				return nil, errors.New("batch get profiles: keys left unprocessed")
			}
			if attempt > 0 {
				time.Sleep(time.Duration(25<<attempt) * time.Millisecond)
			}
			res, err := s.Client.BatchGetItem(ctx, &dynamodb.BatchGetItemInput{RequestItems: req})
			if err != nil {
				return nil, fmt.Errorf("batch get profiles: %w", err)
			}
			var batch []Profile
			if err := attributevalue.UnmarshalListOfMaps(res.Responses[s.Table], &batch); err != nil {
				return nil, fmt.Errorf("unmarshal profiles: %w", err)
			}
			for _, p := range batch {
				if p.DisplayName != "" {
					out[p.UserID] = p.DisplayName
				}
			}
			req = res.UnprocessedKeys
		}
	}
	return out, nil
}
