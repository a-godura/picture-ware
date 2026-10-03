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
	owner := Member{UserID: "user-1", Name: "ana.silva", JoinedAt: testCreated}
	if err := s.CreateTrip(context.Background(), testTrip, owner); err != nil {
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
	meta := items[0].(map[string]any)["Put"].(map[string]any)["Item"].(map[string]any)
	member := items[1].(map[string]any)["Put"].(map[string]any)["Item"]
	mine := items[2].(map[string]any)["Put"].(map[string]any)["Item"].(map[string]any)
	if n, _ := meta["memberCount"].(map[string]any); n["N"] != "1" {
		t.Errorf("trip's memberCount = %v, want 1", meta["memberCount"])
	}
	if str(member, "name") != "ana.silva" || str(member, "joinedAt") == "" {
		t.Errorf("owner member item = %v", member)
	}
	if _, ok := mine["memberCount"]; ok {
		t.Errorf("memberCount copied into the user's trip list: %v", mine)
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

func TestListOrder(t *testing.T) {
	at := func(s string) *time.Time { v, _ := time.Parse(time.RFC3339Nano, s); return &v }
	// Expected listing order: by capture time across time zones and
	// sub-second precision, undated last by upload time.
	ordered := []Photo{
		{ID: "z", TakenAt: at("2026-10-01T10:00:00+02:00")}, // 08:00Z
		{ID: "a", TakenAt: at("2026-10-01T09:00:00Z")},
		{ID: "b", TakenAt: at("2026-10-01T09:00:00.5Z")},
		{ID: "c", TakenAt: at("2026-10-01T09:00:01Z")},
		{ID: "u1", CreatedAt: *at("2026-09-01T00:00:00Z")},
		{ID: "u2", CreatedAt: *at("2026-10-01T00:00:00Z")},
	}
	for i := 1; i < len(ordered); i++ {
		if !(readySK(ordered[i-1]) < readySK(ordered[i])) {
			t.Errorf("%s (%s) should sort before %s (%s)", ordered[i-1].ID, readySK(ordered[i-1]), ordered[i].ID, readySK(ordered[i]))
		}
	}
}

func TestCursorRoundTrip(t *testing.T) {
	sk := readySK(testPhoto)
	got, err := DecodeCursor(EncodeCursor(sk))
	if err != nil || got != sk {
		t.Fatalf("DecodeCursor = %q, %v", got, err)
	}
	for _, bad := range []string{"%%%", EncodeCursor("PHOTO#x"), EncodeCursor("MEMBER#u"), EncodeCursor("READY#" + strings.Repeat("x", 600))} {
		if _, err := DecodeCursor(bad); !errors.Is(err, ErrInvalidCursor) || !errors.Is(err, ErrValidation) {
			t.Errorf("DecodeCursor(%q) err = %v", bad, err)
		}
	}
}

func TestListReadyPhotosQueriesOnlyReadyRangeOnePage(t *testing.T) {
	ready := testPhoto
	ready.Status = StatusReady
	it, _ := item(tripPK("trip-1"), readySK(ready), "readyPhoto", ready)
	page, _ := json.Marshal(map[string]any{
		"Items":            []any{toJSON(t, it)},
		"LastEvaluatedKey": map[string]any{"PK": map[string]string{"S": "TRIP#trip-1"}, "SK": map[string]string{"S": readySK(ready)}},
	})
	s, f := newFakeStore(t, func(string, int) (int, string) { return http.StatusOK, string(page) })
	got, next, err := s.ListReadyPhotos(context.Background(), "trip-1", 1, "")
	if err != nil || len(got) != 1 || got[0].ID != "photo-1" || next != EncodeCursor(readySK(ready)) {
		t.Fatalf("ListReadyPhotos = %+v, %q, %v", got, next, err)
	}
	if len(f.calls) != 1 {
		t.Fatalf("%d calls, want exactly one page", len(f.calls))
	}
	q := f.calls[0].Body
	vals, _ := q["ExpressionAttributeValues"].(map[string]any)
	if q["Limit"] != float64(1) || q["FilterExpression"] != nil || str(vals, ":sk") != "READY#" || q["ExclusiveStartKey"] != nil {
		t.Fatalf("query = %v", q)
	}

	// Next page starts after the cursor; no LastEvaluatedKey means no cursor.
	s, f = newFakeStore(t, func(string, int) (int, string) { return http.StatusOK, `{"Items":[]}` })
	got, next, err = s.ListReadyPhotos(context.Background(), "trip-1", 200, EncodeCursor(readySK(ready)))
	if err != nil || len(got) != 0 || next != "" {
		t.Fatalf("second page = %+v, %q, %v", got, next, err)
	}
	if str(f.calls[0].Body["ExclusiveStartKey"], "SK") != readySK(ready) {
		t.Fatalf("ExclusiveStartKey = %v", f.calls[0].Body["ExclusiveStartKey"])
	}

	// A bad cursor never reaches DynamoDB.
	s, f = newFakeStore(t, nil)
	if _, _, err := s.ListReadyPhotos(context.Background(), "trip-1", 200, "bogus!"); !errors.Is(err, ErrInvalidCursor) || len(f.calls) != 0 {
		t.Fatalf("bad cursor: err %v, %d calls", err, len(f.calls))
	}
}

// getResponse is a GetItem response holding p's PHOTO# record.
func getResponse(t *testing.T, p Photo) string {
	it, _ := item(tripPK(p.TripID), photoSK(p.ID), "photo", p)
	b, _ := json.Marshal(map[string]any{"Item": toJSON(t, it)})
	return string(b)
}

func TestMarkReady(t *testing.T) {
	s, f := newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "GetItem" {
			return http.StatusOK, getResponse(t, testPhoto)
		}
		return http.StatusOK, "{}"
	})
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 42); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 2 || f.calls[1].Op != "TransactWriteItems" {
		t.Fatalf("calls = %+v", f.calls)
	}
	items := f.calls[1].Body["TransactItems"].([]any)
	update := items[0].(map[string]any)["Update"].(map[string]any)
	put := items[1].(map[string]any)["Put"].(map[string]any)
	vals, _ := update["ExpressionAttributeValues"].(map[string]any)
	size, _ := vals[":size"].(map[string]any)
	if update["ConditionExpression"] != "#s = :pending" || str(update["Key"], "SK") != "PHOTO#photo-1" || size["N"] != "42" {
		t.Fatalf("update = %v", update)
	}
	want := readySK(testPhoto)
	if str(put["Item"], "SK") != want || str(put["Item"], "status") != StatusReady || str(put["Item"], "uploaderId") != "user-2" {
		t.Fatalf("listing item = %v, want SK %s", put["Item"], want)
	}

	// Already ready (duplicate S3 event): no write.
	ready := testPhoto
	ready.Status = StatusReady
	s, f = newFakeStore(t, func(string, int) (int, string) { return http.StatusOK, getResponse(t, ready) })
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 42); err != nil || len(f.calls) != 1 {
		t.Fatalf("duplicate: err %v, %d calls", err, len(f.calls))
	}

	// No record.
	s, _ = newFakeStore(t, func(string, int) (int, string) { return http.StatusOK, "{}" })
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 42); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing: err %v", err)
	}

	// Lost a race (deleted meanwhile): retryable error, not "not found".
	s, _ = newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "GetItem" {
			return http.StatusOK, getResponse(t, testPhoto)
		}
		return http.StatusBadRequest, transactionConditionFailed
	})
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 42); err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("race: err %v", err)
	}
}

const transactionConditionFailed = `{"__type":"com.amazonaws.dynamodb.v20120810#TransactionCanceledException","message":"Transaction cancelled","CancellationReasons":[{"Code":"ConditionalCheckFailed"},{"Code":"None"}]}`

func TestDeletePhoto(t *testing.T) {
	ready := testPhoto
	ready.Status = StatusReady

	// Ready: record and listing copy go together.
	s, f := newFakeStore(t, nil)
	if err := s.DeletePhoto(context.Background(), ready); err != nil {
		t.Fatal(err)
	}
	items := f.calls[0].Body["TransactItems"].([]any)
	var sks []string
	for _, ti := range items {
		sks = append(sks, str(ti.(map[string]any)["Delete"].(map[string]any)["Key"], "SK"))
	}
	if f.calls[0].Op != "TransactWriteItems" || strings.Join(sks, " ") != "PHOTO#photo-1 "+readySK(ready) {
		t.Fatalf("delete = %s %v", f.calls[0].Op, sks)
	}
	s, _ = newFakeStore(t, func(string, int) (int, string) { return http.StatusBadRequest, transactionConditionFailed })
	if err := s.DeletePhoto(context.Background(), ready); !errors.Is(err, ErrNotFound) {
		t.Fatalf("ready already gone: err %v", err)
	}

	// Pending: just the record, only while still pending.
	s, f = newFakeStore(t, nil)
	if err := s.DeletePhoto(context.Background(), testPhoto); err != nil {
		t.Fatal(err)
	}
	if b := f.calls[0].Body; f.calls[0].Op != "DeleteItem" || b["ConditionExpression"] != "#s = :pending" || str(b["Key"], "SK") != "PHOTO#photo-1" {
		t.Fatalf("delete = %+v", f.calls[0])
	}
	s, _ = newFakeStore(t, func(string, int) (int, string) { return http.StatusBadRequest, conditionFailed })
	if err := s.DeletePhoto(context.Background(), testPhoto); err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("pending became ready: err %v", err)
	}
}

func TestPutPhotoDuplicateIsError(t *testing.T) {
	s, _ := newFakeStore(t, func(string, int) (int, string) { return http.StatusBadRequest, conditionFailed })
	if err := s.PutPhoto(context.Background(), testPhoto); err == nil || errors.Is(err, ErrNotFound) {
		t.Errorf("PutPhoto err = %v", err)
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
