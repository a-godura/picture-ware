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

const memberSKPrefix = "MEMBER#"

func invitePK(code string) string { return "INVITE#" + code }

// ListMembers returns everyone in the trip, in no particular order.
func (s *DynamoStore) ListMembers(ctx context.Context, tripID string) ([]Member, error) {
	var out []Member
	err := s.query(ctx, tripPK(tripID), memberSKPrefix, func(items []map[string]types.AttributeValue) error {
		var batch []Member
		if err := attributevalue.UnmarshalListOfMaps(items, &batch); err != nil {
			return fmt.Errorf("unmarshal members: %w", err)
		}
		out = append(out, batch...)
		return nil
	})
	return out, err
}

// GetMember returns one member, or ErrNotFound.
func (s *DynamoStore) GetMember(ctx context.Context, tripID, userID string) (Member, error) {
	var m Member
	err := s.get(ctx, tripPK(tripID), memberSK(userID), &m)
	return m, err
}

// GetInvite returns the invite with this code, or ErrNotFound (unknown or
// rotated away).
func (s *DynamoStore) GetInvite(ctx context.Context, code string) (Invite, error) {
	var inv Invite
	err := s.get(ctx, invitePK(code), metaSK, &inv)
	return inv, err
}

// PutInvite makes inv its trip's active invite, replacing previous ("" when
// the trip has none), whose code stops working. It returns ErrConflict if
// the trip's active code is no longer previous (someone else changed it
// first), and ErrNotFound if the trip is gone.
func (s *DynamoStore) PutInvite(ctx context.Context, inv Invite, previous string) error {
	it, err := item(invitePK(inv.Code), metaSK, "invite", inv)
	if err != nil {
		return err
	}
	cond := "attribute_exists(PK) AND attribute_not_exists(inviteCode)"
	values := map[string]types.AttributeValue{":new": &types.AttributeValueMemberS{Value: inv.Code}}
	if previous != "" {
		cond = "attribute_exists(PK) AND inviteCode = :prev"
		values[":prev"] = &types.AttributeValueMemberS{Value: previous}
	}
	ops := []types.TransactWriteItem{
		{Put: &types.Put{TableName: &s.Table, Item: it, ConditionExpression: aws.String(attributeAbsent)}},
		{Update: &types.Update{
			TableName: &s.Table, Key: key(tripPK(inv.TripID), metaSK),
			UpdateExpression:                    aws.String("SET inviteCode = :new"),
			ConditionExpression:                 aws.String(cond),
			ExpressionAttributeValues:           values,
			ReturnValuesOnConditionCheckFailure: types.ReturnValuesOnConditionCheckFailureAllOld,
		}},
	}
	if previous != "" {
		ops = append(ops, types.TransactWriteItem{Delete: &types.Delete{TableName: &s.Table, Key: key(invitePK(previous), metaSK)}})
	}
	_, err = s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{TransactItems: ops})
	if reasons, ok := cancellationReasons(err); ok {
		if failed(reasons, 1) {
			if reasons[1].Item == nil {
				return ErrNotFound
			}
			return ErrConflict
		}
		if failed(reasons, 0) { // 128-bit code collision: practically impossible
			return ErrConflict
		}
	}
	if err != nil {
		return fmt.Errorf("put invite: %w", err)
	}
	return nil
}

// AddMember adds m to trip t through the invite code, all or nothing: the
// member record, their "my trips" entry and the trip's member count. It
// returns ErrAlreadyMember if they're in already, ErrNotFound if the code is
// no longer the trip's active one (or the trip is gone), and ErrTripFull at
// MaxMembers.
func (s *DynamoStore) AddMember(ctx context.Context, t Trip, m Member, code string) error {
	member, err := item(tripPK(t.ID), memberSK(m.UserID), "member", m)
	if err != nil {
		return err
	}
	mine, err := item(userPK(m.UserID), tripSKPrefix+t.ID, "userTrip", t.summary())
	if err != nil {
		return err
	}
	_, err = s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
		TransactItems: []types.TransactWriteItem{
			{Put: &types.Put{TableName: &s.Table, Item: member, ConditionExpression: aws.String(attributeAbsent)}},
			{Put: &types.Put{TableName: &s.Table, Item: mine}},
			{Update: &types.Update{
				TableName:        &s.Table,
				Key:              key(tripPK(t.ID), metaSK),
				UpdateExpression: aws.String("SET memberCount = if_not_exists(memberCount, :one) + :one"),
				ConditionExpression: aws.String("attribute_exists(PK) AND inviteCode = :code AND " +
					"(attribute_not_exists(memberCount) OR memberCount < :max)"),
				ExpressionAttributeValues: map[string]types.AttributeValue{
					":one":  &types.AttributeValueMemberN{Value: "1"},
					":code": &types.AttributeValueMemberS{Value: code},
					":max":  &types.AttributeValueMemberN{Value: strconv.Itoa(MaxMembers)},
				},
				ReturnValuesOnConditionCheckFailure: types.ReturnValuesOnConditionCheckFailureAllOld,
			}},
		},
	})
	if reasons, ok := cancellationReasons(err); ok {
		switch {
		case failed(reasons, 0):
			return ErrAlreadyMember
		case failed(reasons, 2):
			var meta Trip
			if reasons[2].Item == nil {
				return ErrNotFound
			}
			if err := attributevalue.UnmarshalMap(reasons[2].Item, &meta); err != nil {
				return fmt.Errorf("unmarshal trip: %w", err)
			}
			if meta.InviteCode != code {
				return ErrNotFound
			}
			return ErrTripFull
		}
	}
	if err != nil {
		return fmt.Errorf("add member: %w", err)
	}
	return nil
}

// RemoveMember takes userID out of the trip: their member record, their "my
// trips" entry and one off the member count. Their photos stay. It returns
// ErrNotFound if they aren't a member.
func (s *DynamoStore) RemoveMember(ctx context.Context, tripID, userID string) error {
	_, err := s.Client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
		TransactItems: []types.TransactWriteItem{
			{Delete: &types.Delete{
				TableName: &s.Table, Key: key(tripPK(tripID), memberSK(userID)),
				ConditionExpression: aws.String(attributeExists),
			}},
			{Delete: &types.Delete{TableName: &s.Table, Key: key(userPK(userID), tripSKPrefix+tripID)}},
			{Update: &types.Update{
				TableName:           &s.Table,
				Key:                 key(tripPK(tripID), metaSK),
				UpdateExpression:    aws.String("SET memberCount = if_not_exists(memberCount, :one) - :one"),
				ConditionExpression: aws.String(attributeExists),
				ExpressionAttributeValues: map[string]types.AttributeValue{
					":one": &types.AttributeValueMemberN{Value: "1"},
				},
			}},
		},
	})
	if reasons, ok := cancellationReasons(err); ok && (failed(reasons, 0) || failed(reasons, 2)) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("remove member: %w", err)
	}
	return nil
}

// cancellationReasons unwraps a cancelled transaction's per-item reasons
// (in TransactItems order).
func cancellationReasons(err error) ([]types.CancellationReason, bool) {
	var tce *types.TransactionCanceledException
	if !errors.As(err, &tce) {
		return nil, false
	}
	return tce.CancellationReasons, true
}

func failed(reasons []types.CancellationReason, i int) bool {
	return i < len(reasons) && aws.ToString(reasons[i].Code) == "ConditionalCheckFailed"
}
