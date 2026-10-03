package photos

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// fakeDynamo is a tiny stand-in for the DynamoDB JSON endpoint: it records
// each call's operation and request body and answers with canned responses,
// so DynamoStore runs through the real SDK without AWS.
type fakeDynamo struct {
	mu    sync.Mutex
	calls []dynamoCall
	// respond returns status and body for an operation (e.g. "PutItem").
	respond func(op string, call int) (int, string)
}

type dynamoCall struct {
	Op   string
	Body map[string]any
}

func newFakeStore(t *testing.T, respond func(op string, call int) (int, string)) (*DynamoStore, *fakeDynamo) {
	t.Helper()
	f := &fakeDynamo{respond: respond}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, op, _ := strings.Cut(r.Header.Get("X-Amz-Target"), ".")
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		f.mu.Lock()
		n := len(f.calls)
		f.calls = append(f.calls, dynamoCall{Op: op, Body: body})
		f.mu.Unlock()
		status, out := http.StatusOK, "{}"
		if f.respond != nil {
			status, out = f.respond(op, n)
		}
		w.Header().Set("Content-Type", "application/x-amz-json-1.0")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, out)
	}))
	t.Cleanup(srv.Close)
	client := dynamodb.New(dynamodb.Options{
		Region:           "us-east-2",
		BaseEndpoint:     aws.String(srv.URL),
		Credentials:      aws.NewCredentialsCache(credentials.NewStaticCredentialsProvider("AKIDTEST", "secret", "")),
		RetryMaxAttempts: 1,
	})
	return &DynamoStore{Client: client, Table: "AppTable"}, f
}

const conditionFailed = `{"__type":"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException","message":"The conditional request failed"}`

// str digs a DynamoDB JSON string value out of a decoded request item.
func str(item any, attr string) string {
	m, _ := item.(map[string]any)
	v, _ := m[attr].(map[string]any)
	s, _ := v["S"].(string)
	return s
}

var (
	testTaken   = time.Date(2026, 10, 1, 15, 20, 11, 0, time.UTC)
	testCreated = time.Date(2026, 10, 1, 15, 22, 40, 0, time.UTC)
	testTrip    = Trip{ID: "trip-1", Name: "Lisbon", StartDate: "2026-10-01", EndDate: "2026-10-06", CreatedBy: "user-1", CreatedAt: testCreated}
	testPhoto   = Photo{TripID: "trip-1", ID: "photo-1", UploaderID: "user-2", Lat: 38.69, Lng: -9.21, TakenAt: &testTaken,
		ContentType: "image/heic", Status: StatusPending, CreatedAt: testCreated}
)

func TestItemShapeAndRoundTrip(t *testing.T) {
	it, err := item(tripPK("trip-1"), photoSK("photo-1"), "photo", testPhoto)
	if err != nil {
		t.Fatal(err)
	}
	for attr, want := range map[string]string{"PK": "TRIP#trip-1", "SK": "PHOTO#photo-1", "type": "photo", "uploaderId": "user-2", "status": StatusPending} {
		if got := it[attr].(*types.AttributeValueMemberS).Value; got != want {
			t.Errorf("%s = %q, want %q", attr, got, want)
		}
	}
	var back Photo
	if err := attributevalue.UnmarshalMap(it, &back); err != nil {
		t.Fatal(err)
	}
	if back.ID != testPhoto.ID || back.TripID != testPhoto.TripID || !back.TakenAt.Equal(testTaken) || back.Lat != testPhoto.Lat {
		t.Fatalf("round trip = %+v", back)
	}

	// Optional fields are omitted, not stored empty.
	undated := testPhoto
	undated.TakenAt = nil
	it, _ = item("pk", "sk", "photo", undated)
	if _, ok := it["takenAt"]; ok {
		t.Error("nil takenAt stored")
	}
	open := testTrip
	open.EndDate = ""
	it, _ = item("pk", "sk", "trip", open)
	if _, ok := it["endDate"]; ok {
		t.Error("empty endDate stored")
	}
}

func TestCreateTripWritesThreeItemsAtomically(t *testing.T) {
	s, f := newFakeStore(t, nil)
	if err := s.CreateTrip(context.Background(), testTrip); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 1 || f.calls[0].Op != "TransactWriteItems" {
		t.Fatalf("calls = %+v", f.calls)
	}
	items, _ := f.calls[0].Body["TransactItems"].([]any)
	var keys []string
	for _, ti := range items {
		put := ti.(map[string]any)["Put"].(map[string]any)
		if put["ConditionExpression"] != attributeAbsent || put["TableName"] != "AppTable" {
			t.Errorf("put without create-only condition: %v", put)
		}
		keys = append(keys, str(put["Item"], "PK")+" "+str(put["Item"], "SK")+" "+str(put["Item"], "type"))
	}
	want := "TRIP#trip-1 META trip|TRIP#trip-1 MEMBER#user-1 member|USER#user-1 TRIP#trip-1 userTrip"
	if got := strings.Join(keys, "|"); got != want {
		t.Fatalf("items = %s\nwant    %s", got, want)
	}
}

func TestPutPhotoIsCreateOnly(t *testing.T) {
	s, f := newFakeStore(t, nil)
	if err := s.PutPhoto(context.Background(), testPhoto); err != nil {
		t.Fatal(err)
	}
	b := f.calls[0].Body
	if f.calls[0].Op != "PutItem" || b["ConditionExpression"] != attributeAbsent || str(b["Item"], "SK") != "PHOTO#photo-1" {
		t.Fatalf("call = %+v", f.calls[0])
	}
}

func TestGetTrip(t *testing.T) {
	it, _ := item(tripPK("trip-1"), metaSK, "trip", testTrip)
	found, _ := json.Marshal(map[string]any{"Item": toJSON(t, it)})
	s, _ := newFakeStore(t, func(string, int) (int, string) { return http.StatusOK, string(found) })
	got, err := s.GetTrip(context.Background(), "trip-1")
	if err != nil || got != testTrip {
		t.Fatalf("GetTrip = %+v, %v", got, err)
	}

	s, _ = newFakeStore(t, func(string, int) (int, string) { return http.StatusOK, "{}" })
	if _, err := s.GetTrip(context.Background(), "trip-1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing trip err = %v", err)
	}
}

func TestIsMember(t *testing.T) {
	for _, tt := range []struct {
		body string
		want bool
	}{{`{"Item":{"PK":{"S":"TRIP#trip-1"}}}`, true}, {`{}`, false}} {
		s, f := newFakeStore(t, func(string, int) (int, string) { return http.StatusOK, tt.body })
		got, err := s.IsMember(context.Background(), "trip-1", "user-1")
		if err != nil || got != tt.want {
			t.Fatalf("IsMember = %v, %v; want %v", got, err, tt.want)
		}
		if k := f.calls[0].Body["Key"]; str(k, "SK") != "MEMBER#user-1" {
			t.Fatalf("key = %v", k)
		}
	}
}

func TestListReadyPhotosPagesAndFilters(t *testing.T) {
	p1, _ := item("TRIP#trip-1", "PHOTO#a", "photo", Photo{TripID: "trip-1", ID: "a", Status: StatusReady})
	p2, _ := item("TRIP#trip-1", "PHOTO#b", "photo", Photo{TripID: "trip-1", ID: "b", Status: StatusReady})
	pages := []map[string]any{
		{"Items": []any{toJSON(t, p1)}, "LastEvaluatedKey": map[string]any{"PK": map[string]string{"S": "TRIP#trip-1"}, "SK": map[string]string{"S": "PHOTO#a"}}},
		{"Items": []any{toJSON(t, p2)}},
	}
	s, f := newFakeStore(t, func(_ string, n int) (int, string) {
		b, _ := json.Marshal(pages[n])
		return http.StatusOK, string(b)
	})
	got, err := s.ListReadyPhotos(context.Background(), "trip-1")
	if err != nil || len(got) != 2 || got[0].ID != "a" || got[1].ID != "b" {
		t.Fatalf("ListReadyPhotos = %+v, %v", got, err)
	}
	q := f.calls[0].Body
	if q["FilterExpression"] != "#s = :status" || q["KeyConditionExpression"] != "PK = :pk AND begins_with(SK, :sk)" {
		t.Fatalf("query = %v", q)
	}
	if f.calls[1].Body["ExclusiveStartKey"] == nil {
		t.Fatal("second page didn't continue from LastEvaluatedKey")
	}
}

func TestConditionFailedMapsToNotFound(t *testing.T) {
	s, _ := newFakeStore(t, func(string, int) (int, string) { return http.StatusBadRequest, conditionFailed })
	if err := s.DeletePhoto(context.Background(), "trip-1", "photo-1"); !errors.Is(err, ErrNotFound) {
		t.Errorf("DeletePhoto err = %v", err)
	}
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 42); !errors.Is(err, ErrNotFound) {
		t.Errorf("MarkReady err = %v", err)
	}
	// A duplicate create is an error, not "not found".
	if err := s.PutPhoto(context.Background(), testPhoto); err == nil || errors.Is(err, ErrNotFound) {
		t.Errorf("PutPhoto err = %v", err)
	}
}

func TestMarkReadyRequest(t *testing.T) {
	s, f := newFakeStore(t, nil)
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 42); err != nil {
		t.Fatal(err)
	}
	b := f.calls[0].Body
	vals, _ := b["ExpressionAttributeValues"].(map[string]any)
	size, _ := vals[":size"].(map[string]any)
	if b["ConditionExpression"] != attributeExists || str(b["Key"], "SK") != "PHOTO#photo-1" || size["N"] != "42" {
		t.Fatalf("update = %v", b)
	}
}

// toJSON converts an SDK item to DynamoDB's wire JSON.
func toJSON(t *testing.T, it map[string]types.AttributeValue) map[string]any {
	t.Helper()
	out := map[string]any{}
	for k, v := range it {
		switch v := v.(type) {
		case *types.AttributeValueMemberS:
			out[k] = map[string]string{"S": v.Value}
		case *types.AttributeValueMemberN:
			out[k] = map[string]string{"N": v.Value}
		default:
			t.Fatalf("toJSON: unsupported %T for %s", v, k)
		}
	}
	return out
}
