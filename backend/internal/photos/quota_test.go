package photos

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

var testLimits = Limits{DailyUploads: 300, UserBytes: 5 << 30, TotalBytes: 50 << 30}

// cancelledWith is a TransactionCanceledException with the given per-item
// codes ("" = None).
func cancelledWith(codes ...string) string {
	reasons := make([]map[string]string, len(codes))
	for i, c := range codes {
		if c == "" {
			c = "None"
		}
		reasons[i] = map[string]string{"Code": c}
	}
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

// assertAddCall checks a call is an unconditional UpdateItem adding
// used/stored deltas to pk's USAGE item.
func assertAddCall(t *testing.T, c dynamoCall, pk string, used, stored int64) {
	t.Helper()
	b := c.Body
	if c.Op != "UpdateItem" || str(b["Key"], "PK") != pk || str(b["Key"], "SK") != "USAGE" || b["UpdateExpression"] != "ADD #u :u, #st :st" || b["ConditionExpression"] != nil {
		t.Fatalf("not an ADD on %s USAGE: %s %v", pk, c.Op, b)
	}
	v := b["ExpressionAttributeValues"]
	if numVal(v, ":u") != strconv.FormatInt(used, 10) || numVal(v, ":st") != strconv.FormatInt(stored, 10) {
		t.Fatalf("%s deltas = %v, want used %d stored %d", pk, v, used, stored)
	}
}

func assertPendingDelete(t *testing.T, c dynamoCall, sk string) {
	t.Helper()
	if c.Op != "DeleteItem" || str(c.Body["Key"], "PK") != "USAGE#user-2" || str(c.Body["Key"], "SK") != sk || c.Body["ConditionExpression"] != attributeExists {
		t.Fatalf("not a conditional reservation delete of %s: %s %v", sk, c.Op, c.Body)
	}
}

func transactItems(t *testing.T, c dynamoCall) []any {
	t.Helper()
	if c.Op != "TransactWriteItems" {
		t.Fatalf("op = %s, want TransactWriteItems", c.Op)
	}
	return c.Body["TransactItems"].([]any)
}

func ops(f *fakeDynamo) string {
	var out []string
	for _, c := range f.calls {
		out = append(out, c.Op)
	}
	return strings.Join(out, " ")
}

// usageItem is a GetItem response for a user's USAGE item ("" = no item).
func usageItem(day string, count, used int64) string {
	if day == "" {
		return "{}"
	}
	return fmt.Sprintf(`{"Item":{"PK":{"S":"USAGE#user-2"},"SK":{"S":"USAGE"},"day":{"S":%q},"dayCount":{"N":"%d"},"used":{"N":"%d"}}}`, day, count, used)
}

func TestPutPhotoFirstUploadOfTheDay(t *testing.T) {
	s, f := newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "GetItem" {
			return http.StatusOK, usageItem("2026-09-30", 300, 1<<30) // yesterday's count doesn't matter
		}
		return http.StatusOK, "{}"
	})
	if err := s.PutPhoto(context.Background(), testPhoto, testLimits); err != nil {
		t.Fatal(err)
	}
	if got := ops(f); got != "GetItem UpdateItem TransactWriteItems" {
		t.Fatalf("calls = %s", got)
	}
	if g := f.calls[0].Body; g["ConsistentRead"] != true || str(g["Key"], "PK") != "USAGE#user-2" || str(g["Key"], "SK") != "USAGE" {
		t.Fatalf("usage read = %v", g)
	}

	total := f.calls[1].Body
	if str(total["Key"], "PK") != "USAGE#ALL" || total["ConditionExpression"] != "attribute_not_exists(#u) OR #u <= :room" ||
		numVal(total["ExpressionAttributeValues"], ":n") != strconv.Itoa(MaxUploadBytes) ||
		numVal(total["ExpressionAttributeValues"], ":room") != strconv.FormatInt(testLimits.TotalBytes-MaxUploadBytes, 10) {
		t.Fatalf("total reservation = %v", total)
	}

	items := transactItems(t, f.calls[2])
	if len(items) != 3 {
		t.Fatalf("%d items, want 3 (photo, user usage, reservation)", len(items))
	}
	photo := op(items[0], "Put")
	if photo["ConditionExpression"] != attributeAbsent || str(photo["Item"], "SK") != "PHOTO#photo-1" || numVal(photo["Item"], "reserved") != strconv.Itoa(MaxUploadBytes) {
		t.Fatalf("photo put = %v", photo)
	}
	u := op(items[1], "Update")
	v := u["ExpressionAttributeValues"]
	if str(u["Key"], "PK") != "USAGE#user-2" || u["UpdateExpression"] != "SET #d = :today, #dc = :one ADD #u :res" ||
		u["ConditionExpression"] != "(attribute_not_exists(#d) OR #d <> :today) AND (attribute_not_exists(#u) OR #u <= :room)" ||
		str(v, ":today") != "2026-10-01" || numVal(v, ":room") != strconv.FormatInt(testLimits.UserBytes-MaxUploadBytes, 10) {
		t.Fatalf("user usage update = %v", u)
	}
	pending := op(items[2], "Put")["Item"]
	if str(pending, "PK") != "USAGE#user-2" || str(pending, "SK") != pendingSK(testPhoto) ||
		str(pending, "tripId") != "trip-1" || str(pending, "photoId") != "photo-1" || numVal(pending, "bytes") != strconv.Itoa(MaxUploadBytes) {
		t.Fatalf("pending item = %v", pending)
	}
}

func TestPutPhotoSameDay(t *testing.T) {
	s, f := newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "GetItem" {
			return http.StatusOK, usageItem("2026-10-01", 5, 100)
		}
		return http.StatusOK, "{}"
	})
	if err := s.PutPhoto(context.Background(), testPhoto, testLimits); err != nil {
		t.Fatal(err)
	}
	u := op(transactItems(t, f.calls[2])[1], "Update")
	if u["UpdateExpression"] != "ADD #dc :one, #u :res" || u["ConditionExpression"] != "#d = :today AND #dc < :max AND #u <= :room" ||
		numVal(u["ExpressionAttributeValues"], ":max") != "300" {
		t.Fatalf("user usage update = %v", u)
	}
}

func TestPutPhotoOverQuota(t *testing.T) {
	room := testLimits.UserBytes - MaxUploadBytes
	for name, tt := range map[string]struct {
		usage    string
		total    string // UpdateItem response
		want     error
		wantOps  string
		giveBack bool
	}{
		"daily":         {usage: usageItem("2026-10-01", 300, 0), want: ErrDailyLimit, wantOps: "GetItem"},
		"user storage":  {usage: usageItem("2026-10-01", 1, room+1), want: ErrUserStorage, wantOps: "GetItem"},
		"total storage": {usage: "{}", total: conditionFailed, want: ErrTotalStorage, wantOps: "GetItem UpdateItem"},
	} {
		t.Run(name, func(t *testing.T) {
			s, f := newFakeStore(t, func(op string, _ int) (int, string) {
				switch {
				case op == "GetItem":
					return http.StatusOK, tt.usage
				case op == "UpdateItem" && tt.total != "":
					return http.StatusBadRequest, tt.total
				}
				return http.StatusOK, "{}"
			})
			if err := s.PutPhoto(context.Background(), testPhoto, testLimits); !errors.Is(err, tt.want) {
				t.Fatalf("err %v, want %v", err, tt.want)
			}
			if got := ops(f); got != tt.wantOps {
				t.Fatalf("calls = %s, want %s", got, tt.wantOps)
			}
		})
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

func TestPutPhotoRacesReReadAndGiveBackTotal(t *testing.T) {
	for _, code := range []string{"ConditionalCheckFailed", "TransactionConflict"} {
		t.Run(code, func(t *testing.T) {
			// First read: 299 today. The transaction loses a race (someone
			// else took the 300th); the re-read shows the limit.
			reads := 0
			s, f := newFakeStore(t, func(op string, _ int) (int, string) {
				switch op {
				case "GetItem":
					reads++
					if reads == 1 {
						return http.StatusOK, usageItem("2026-10-01", 299, 0)
					}
					return http.StatusOK, usageItem("2026-10-01", 300, 0)
				case "TransactWriteItems":
					return http.StatusBadRequest, cancelledWith("", code, "")
				}
				return http.StatusOK, "{}"
			})
			if err := s.PutPhoto(context.Background(), testPhoto, testLimits); !errors.Is(err, ErrDailyLimit) {
				t.Fatalf("err %v", err)
			}
			if got := ops(f); got != "GetItem UpdateItem TransactWriteItems UpdateItem GetItem" {
				t.Fatalf("calls = %s", got)
			}
			assertAddCall(t, f.calls[3], "USAGE#ALL", -MaxUploadBytes, 0)
		})
	}

	// Duplicate id: an error (not a quota one), total given back, no retry.
	s, f := newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "TransactWriteItems" {
			return http.StatusBadRequest, cancelledWith("ConditionalCheckFailed", "", "")
		}
		return http.StatusOK, "{}"
	})
	err := s.PutPhoto(context.Background(), testPhoto, testLimits)
	if err == nil || errors.Is(err, ErrDailyLimit) || errors.Is(err, ErrUserStorage) || errors.Is(err, ErrTotalStorage) {
		t.Fatalf("duplicate: err %v", err)
	}
	if got := ops(f); got != "GetItem UpdateItem TransactWriteItems UpdateItem" {
		t.Fatalf("duplicate calls = %s", got)
	}

	// Constant contention: gives up after putAttempts with a retryable error.
	s, f = newFakeStore(t, func(op string, _ int) (int, string) {
		if op == "TransactWriteItems" {
			return http.StatusBadRequest, cancelledWith("", "TransactionConflict", "")
		}
		return http.StatusOK, "{}"
	})
	if err := s.PutPhoto(context.Background(), testPhoto, testLimits); !errors.Is(err, errChanged) {
		t.Fatalf("contention: err %v", err)
	}
	if n := strings.Count(ops(f), "TransactWriteItems"); n != putAttempts {
		t.Fatalf("%d attempts, want %d", n, putAttempts)
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
	if got := ops(f); got != "GetItem DeleteItem UpdateItem UpdateItem TransactWriteItems" {
		t.Fatalf("calls = %s", got)
	}
	assertPendingDelete(t, f.calls[1], pendingSK(p))
	assertAddCall(t, f.calls[2], "USAGE#user-2", 1000-MaxUploadBytes, 1000)
	assertAddCall(t, f.calls[3], "USAGE#ALL", 1000-MaxUploadBytes, 1000)
	items := transactItems(t, f.calls[4])
	if len(items) != 2 || op(items[0], "Update")["UpdateExpression"] != "SET #s = :ready, #sz = :size, #ct = :true" {
		t.Fatalf("photo transaction = %v", items)
	}
}

func TestMarkReadyAfterReservationReleased(t *testing.T) {
	p := reservedPhoto()
	s, f := newFakeStore(t, func(op string, _ int) (int, string) {
		switch op {
		case "GetItem":
			return http.StatusOK, getResponse(t, p)
		case "DeleteItem":
			return http.StatusBadRequest, conditionFailed // released as stale
		}
		return http.StatusOK, "{}"
	})
	if err := s.MarkReady(context.Background(), "trip-1", "photo-1", 1000); err != nil {
		t.Fatal(err)
	}
	assertAddCall(t, f.calls[2], "USAGE#user-2", 1000, 1000)
	assertAddCall(t, f.calls[3], "USAGE#ALL", 1000, 1000)
}

func TestDeletePhotoGivesBytesBack(t *testing.T) {
	// Counted ready photo: its size comes off both counters after the delete.
	ready := testPhoto
	ready.Status, ready.Size, ready.Counted = StatusReady, 1000, true
	s, f := newFakeStore(t, nil)
	if err := s.DeletePhoto(context.Background(), ready); err != nil {
		t.Fatal(err)
	}
	if got := ops(f); got != "TransactWriteItems UpdateItem UpdateItem" || len(transactItems(t, f.calls[0])) != 2 {
		t.Fatalf("calls = %s", got)
	}
	assertAddCall(t, f.calls[1], "USAGE#user-2", -1000, -1000)
	assertAddCall(t, f.calls[2], "USAGE#ALL", -1000, -1000)

	// Ready photo from before quotas (never counted): counters untouched.
	ready.Counted = false
	s, f = newFakeStore(t, nil)
	if err := s.DeletePhoto(context.Background(), ready); err != nil || ops(f) != "TransactWriteItems" {
		t.Fatalf("uncounted: err %v, calls %s", err, ops(f))
	}

	// Pending photo with an outstanding reservation: released after the record.
	p := reservedPhoto()
	s, f = newFakeStore(t, nil)
	if err := s.DeletePhoto(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	if got := ops(f); got != "DeleteItem DeleteItem UpdateItem UpdateItem" {
		t.Fatalf("calls = %s", got)
	}
	if b := f.calls[0].Body; str(b["Key"], "SK") != "PHOTO#photo-1" || b["ConditionExpression"] != "#s = :pending" {
		t.Fatalf("photo delete = %v", b)
	}
	assertPendingDelete(t, f.calls[1], pendingSK(p))
	assertAddCall(t, f.calls[2], "USAGE#user-2", -MaxUploadBytes, 0)
	assertAddCall(t, f.calls[3], "USAGE#ALL", -MaxUploadBytes, 0)

	// Reservation already gone (released as stale or swapped): nothing to give back.
	s, f = newFakeStore(t, func(_ string, n int) (int, string) {
		if n == 1 {
			return http.StatusBadRequest, conditionFailed
		}
		return http.StatusOK, "{}"
	})
	if err := s.DeletePhoto(context.Background(), p); err != nil || ops(f) != "DeleteItem DeleteItem" {
		t.Fatalf("released: err %v, calls %s", err, ops(f))
	}

	// Became ready meanwhile: retryable error, reservation untouched.
	s, f = newFakeStore(t, func(string, int) (int, string) { return http.StatusBadRequest, conditionFailed })
	if err := s.DeletePhoto(context.Background(), p); err == nil || errors.Is(err, ErrNotFound) || len(f.calls) != 1 {
		t.Fatalf("pending became ready: err %v, calls %s", err, ops(f))
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
		case n == 4: // "b" settled concurrently
			return http.StatusBadRequest, conditionFailed
		}
		return http.StatusOK, "{}"
	})
	cutoff := time.Date(2026, 10, 1, 11, 0, 0, 0, time.UTC)
	n, err := s.ReleaseStaleReservations(context.Background(), "user-2", cutoff)
	if err != nil || n != 1 {
		t.Fatalf("released %d, %v; want 1", n, err)
	}
	if got := ops(f); got != "Query DeleteItem UpdateItem UpdateItem DeleteItem" {
		t.Fatalf("calls = %s", got)
	}
	q := f.calls[0].Body
	vals := q["ExpressionAttributeValues"]
	if q["KeyConditionExpression"] != "PK = :pk AND SK BETWEEN :from AND :to" || str(vals, ":pk") != "USAGE#user-2" ||
		str(vals, ":from") != "PENDING#" || str(vals, ":to") != "PENDING#2026-10-01T11:00:00.000000000Z" {
		t.Fatalf("query = %v", q)
	}
	assertPendingDelete(t, f.calls[1], "PENDING#2026-10-01T10:00:00.000000000Z#trip-1#a")
	assertAddCall(t, f.calls[2], "USAGE#user-2", -MaxUploadBytes, 0)
	assertAddCall(t, f.calls[3], "USAGE#ALL", -MaxUploadBytes, 0)
}
