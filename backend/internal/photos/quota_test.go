package photos

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"testing"
	"time"
)

var testLimits = Limits{DailyUploads: 300, UserBytes: 5 << 30, TotalBytes: 50 << 30}

// cancelledAt is a TransactionCanceledException whose item i (of n) failed
// its condition.
func cancelledAt(n, i int) string {
	reasons := make([]map[string]string, n)
	for j := range reasons {
		reasons[j] = map[string]string{"Code": "None"}
	}
	reasons[i]["Code"] = "ConditionalCheckFailed"
	b, _ := json.Marshal(map[string]any{
		"__type":              "com.amazonaws.dynamodb.v20120810#TransactionCanceledException",
		"message":             "Transaction cancelled",
		"CancellationReasons": reasons,
	})
	return string(b)
}

func op(ti any, kind string) map[string]any {
	m, _ := ti.(map[string]any)[kind].(map[string]any)
	return m
}

func numVal(vals any, name string) string {
	m, _ := vals.(map[string]any)
	v, _ := m[name].(map[string]any)
	s, _ := v["N"].(string)
	return s
}

// assertAdd checks a transact item is an unconditional ADD of used/stored
// deltas to pk's BYTES counter.
func assertAdd(t *testing.T, ti any, pk string, used, stored int64) {
	t.Helper()
	u := op(ti, "Update")
	if u == nil || str(u["Key"], "PK") != pk || str(u["Key"], "SK") != "BYTES" || u["UpdateExpression"] != "ADD #u :u, #st :st" || u["ConditionExpression"] != nil {
		t.Fatalf("not an ADD on %s BYTES: %v", pk, ti)
	}
	if numVal(u["ExpressionAttributeValues"], ":u") != strconv.FormatInt(used, 10) || numVal(u["ExpressionAttributeValues"], ":st") != strconv.FormatInt(stored, 10) {
		t.Fatalf("%s deltas = %v, want used %d stored %d", pk, u["ExpressionAttributeValues"], used, stored)
	}
}

func transactItems(t *testing.T, c dynamoCall) []any {
	t.Helper()
	if c.Op != "TransactWriteItems" {
		t.Fatalf("op = %s, want TransactWriteItems", c.Op)
	}
	return c.Body["TransactItems"].([]any)
}

func TestPutPhotoReservesAtomically(t *testing.T) {
	s, f := newFakeStore(t, nil)
	if err := s.PutPhoto(context.Background(), testPhoto, testLimits); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 1 {
		t.Fatalf("calls = %+v", f.calls)
	}
	items := transactItems(t, f.calls[0])
	if len(items) != 5 {
		t.Fatalf("%d items, want 5", len(items))
	}

	photo := op(items[0], "Put")
	if photo["ConditionExpression"] != attributeAbsent || str(photo["Item"], "SK") != "PHOTO#photo-1" || numVal(photo["Item"], "reserved") != strconv.Itoa(MaxUploadBytes) {
		t.Fatalf("photo put = %v", photo)
	}

	day := op(items[1], "Update")
	dv := day["ExpressionAttributeValues"]
	wantTTL := time.Date(2026, 10, 3, 0, 0, 0, 0, time.UTC).Unix() // created 2026-10-01 + 2 days
	if str(day["Key"], "PK") != "USAGE#user-2" || str(day["Key"], "SK") != "DAY#2026-10-01" ||
		day["ConditionExpression"] != "attribute_not_exists(#c) OR #c < :max" ||
		numVal(dv, ":max") != "300" || numVal(dv, ":one") != "1" || numVal(dv, ":ttl") != strconv.FormatInt(wantTTL, 10) {
		t.Fatalf("day counter = %v", day)
	}

	for i, want := range []struct {
		pk    string
		limit int64
	}{{"USAGE#user-2", testLimits.UserBytes}, {"USAGE#ALL", testLimits.TotalBytes}} {
		u := op(items[2+i], "Update")
		v := u["ExpressionAttributeValues"]
		if str(u["Key"], "PK") != want.pk || str(u["Key"], "SK") != "BYTES" || u["ConditionExpression"] != "attribute_not_exists(#u) OR #u <= :room" ||
			numVal(v, ":n") != strconv.Itoa(MaxUploadBytes) || numVal(v, ":room") != strconv.FormatInt(want.limit-MaxUploadBytes, 10) {
			t.Fatalf("reservation on %s = %v", want.pk, u)
		}
	}

	pending := op(items[4], "Put")["Item"]
	if str(pending, "PK") != "USAGE#user-2" || str(pending, "SK") != pendingSK(testPhoto) ||
		str(pending, "tripId") != "trip-1" || str(pending, "photoId") != "photo-1" || numVal(pending, "bytes") != strconv.Itoa(MaxUploadBytes) {
		t.Fatalf("pending item = %v", pending)
	}
}

func TestPutPhotoOverQuota(t *testing.T) {
	for i, want := range map[int]error{1: ErrDailyLimit, 2: ErrUserStorage, 3: ErrTotalStorage} {
		s, _ := newFakeStore(t, func(string, int) (int, string) { return http.StatusBadRequest, cancelledAt(5, i) })
		if err := s.PutPhoto(context.Background(), testPhoto, testLimits); !errors.Is(err, want) {
			t.Errorf("item %d failed: err %v, want %v", i, err, want)
		}
	}

	// Duplicate id: an error, but not a quota error.
	s, _ := newFakeStore(t, func(string, int) (int, string) { return http.StatusBadRequest, cancelledAt(5, 0) })
	err := s.PutPhoto(context.Background(), testPhoto, testLimits)
	if err == nil || errors.Is(err, ErrDailyLimit) || errors.Is(err, ErrUserStorage) || errors.Is(err, ErrTotalStorage) {
		t.Errorf("duplicate: err %v", err)
	}

	// Limits too small for even one upload never reach DynamoDB.
	for _, tt := range []struct {
		lim  Limits
		want error
	}{
		{Limits{DailyUploads: 0, UserBytes: 5 << 30, TotalBytes: 50 << 30}, ErrDailyLimit},
		{Limits{DailyUploads: 1, UserBytes: MaxUploadBytes - 1, TotalBytes: 50 << 30}, ErrUserStorage},
		{Limits{DailyUploads: 1, UserBytes: 5 << 30, TotalBytes: 1}, ErrTotalStorage},
	} {
		s, f := newFakeStore(t, nil)
		if err := s.PutPhoto(context.Background(), testPhoto, tt.lim); !errors.Is(err, tt.want) || len(f.calls) != 0 {
			t.Errorf("limits %+v: err %v, %d calls", tt.lim, err, len(f.calls))
		}
	}
}

func reservedPhoto() Photo {
	p := testPhoto
	p.Reserved = MaxUploadBytes
	return p
}

func TestMarkReadySwapsReservationForSize(t *testing.T) {
	p := reservedPhoto()
	s, f := newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "GetItem" {
			return http.StatusOK, getResponse(t, p)
		}
		return http.StatusOK, "{}"
	})
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 1000); err != nil {
		t.Fatal(err)
	}
	items := transactItems(t, f.calls[1])
	if len(items) != 5 {
		t.Fatalf("%d items, want 5", len(items))
	}
	if upd := op(items[0], "Update"); upd["UpdateExpression"] != "SET #s = :ready, #sz = :size, #ct = :true" {
		t.Fatalf("photo update = %v", upd)
	}
	del := op(items[2], "Delete")
	if str(del["Key"], "SK") != pendingSK(p) || del["ConditionExpression"] != attributeExists {
		t.Fatalf("reservation delete = %v", del)
	}
	assertAdd(t, items[3], "USAGE#user-2", 1000-MaxUploadBytes, 1000)
	assertAdd(t, items[4], "USAGE#ALL", 1000-MaxUploadBytes, 1000)
}

func TestMarkReadyAfterReservationReleased(t *testing.T) {
	p := reservedPhoto()
	s, f := newFakeStore(t, func(op string, n int) (int, string) {
		switch {
		case op == "GetItem":
			return http.StatusOK, getResponse(t, p)
		case n == 1: // first attempt: the reservation is gone
			return http.StatusBadRequest, cancelledAt(5, 2)
		}
		return http.StatusOK, "{}"
	})
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 1000); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 3 {
		t.Fatalf("%d calls, want get + 2 transactions", len(f.calls))
	}
	items := transactItems(t, f.calls[2])
	if len(items) != 4 {
		t.Fatalf("%d items on retry, want 4 (no reservation delete)", len(items))
	}
	assertAdd(t, items[2], "USAGE#user-2", 1000, 1000)
	assertAdd(t, items[3], "USAGE#ALL", 1000, 1000)

	// Photo itself changed: retryable error, no second attempt.
	s, f = newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "GetItem" {
			return http.StatusOK, getResponse(t, p)
		}
		return http.StatusBadRequest, cancelledAt(5, 0)
	})
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 1000); err == nil || len(f.calls) != 2 {
		t.Fatalf("race: err %v, %d calls", err, len(f.calls))
	}
}

func TestDeletePhotoGivesBytesBack(t *testing.T) {
	// Counted ready photo: its size comes off both counters.
	ready := testPhoto
	ready.Status, ready.Size, ready.Counted = StatusReady, 1000, true
	s, f := newFakeStore(t, nil)
	if err := s.DeletePhoto(context.Background(), ready); err != nil {
		t.Fatal(err)
	}
	items := transactItems(t, f.calls[0])
	if len(items) != 4 {
		t.Fatalf("%d items, want 4", len(items))
	}
	assertAdd(t, items[2], "USAGE#user-2", -1000, -1000)
	assertAdd(t, items[3], "USAGE#ALL", -1000, -1000)

	// Ready photo from before quotas (never counted): counters untouched.
	ready.Counted = false
	s, f = newFakeStore(t, nil)
	if err := s.DeletePhoto(context.Background(), ready); err != nil {
		t.Fatal(err)
	}
	if n := len(transactItems(t, f.calls[0])); n != 2 {
		t.Fatalf("uncounted ready photo: %d items, want 2", n)
	}

	// Pending photo with a reservation: released with the record.
	p := reservedPhoto()
	s, f = newFakeStore(t, nil)
	if err := s.DeletePhoto(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	items = transactItems(t, f.calls[0])
	if len(items) != 4 || op(items[0], "Delete")["ConditionExpression"] != "#s = :pending" || str(op(items[1], "Delete")["Key"], "SK") != pendingSK(p) {
		t.Fatalf("pending delete = %v", items)
	}
	assertAdd(t, items[2], "USAGE#user-2", -MaxUploadBytes, 0)
	assertAdd(t, items[3], "USAGE#ALL", -MaxUploadBytes, 0)

	// Reservation already released as stale: just the record.
	s, f = newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "TransactWriteItems" {
			return http.StatusBadRequest, cancelledAt(4, 1)
		}
		return http.StatusOK, "{}"
	})
	if err := s.DeletePhoto(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 2 || f.calls[1].Op != "DeleteItem" || str(f.calls[1].Body["Key"], "SK") != "PHOTO#photo-1" {
		t.Fatalf("fallback calls = %+v", f.calls)
	}

	// Became ready meanwhile: retryable error.
	s, _ = newFakeStore(t, func(string, int) (int, string) { return http.StatusBadRequest, cancelledAt(4, 0) })
	if err := s.DeletePhoto(context.Background(), p); err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("pending became ready: err %v", err)
	}
}

func TestReleaseStaleReservations(t *testing.T) {
	stale := func(id string) map[string]any {
		return map[string]any{
			"PK": map[string]string{"S": "USAGE#user-2"}, "SK": map[string]string{"S": "PENDING#2026-10-01T10:00:00.000000000Z#trip-1#" + id},
			"tripId": map[string]string{"S": "trip-1"}, "photoId": map[string]string{"S": id}, "bytes": map[string]string{"N": strconv.Itoa(MaxUploadBytes)},
		}
	}
	page, _ := json.Marshal(map[string]any{"Items": []any{stale("a"), stale("b")}})
	s, f := newFakeStore(t, func(op string, n int) (int, string) {
		switch {
		case op == "Query":
			return http.StatusOK, string(page)
		case n == 2: // "b" settled concurrently
			return http.StatusBadRequest, cancelledAt(3, 0)
		}
		return http.StatusOK, "{}"
	})
	cutoff := time.Date(2026, 10, 1, 11, 0, 0, 0, time.UTC)
	n, err := s.ReleaseStaleReservations(context.Background(), "user-2", cutoff)
	if err != nil || n != 1 {
		t.Fatalf("released %d, %v; want 1", n, err)
	}
	q := f.calls[0].Body
	vals := q["ExpressionAttributeValues"]
	if q["KeyConditionExpression"] != "PK = :pk AND SK BETWEEN :from AND :to" || str(vals, ":pk") != "USAGE#user-2" ||
		str(vals, ":from") != "PENDING#" || str(vals, ":to") != "PENDING#2026-10-01T11:00:00.000000000Z" {
		t.Fatalf("query = %v", q)
	}
	items := transactItems(t, f.calls[1])
	if del := op(items[0], "Delete"); str(del["Key"], "SK") != "PENDING#2026-10-01T10:00:00.000000000Z#trip-1#a" || del["ConditionExpression"] != attributeExists {
		t.Fatalf("delete = %v", del)
	}
	assertAdd(t, items[1], "USAGE#user-2", -MaxUploadBytes, 0)
	assertAdd(t, items[2], "USAGE#ALL", -MaxUploadBytes, 0)
}
