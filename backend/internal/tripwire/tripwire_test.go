package tripwire

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
)

// fakeS3 keeps a bucket policy in memory, like S3 does.
type fakeS3 struct {
	policy  string // "" = no policy
	getErr  error
	putErr  error
	puts    int
	lastPut string
}

func (f *fakeS3) GetBucketPolicy(_ context.Context, in *s3.GetBucketPolicyInput, _ ...func(*s3.Options)) (*s3.GetBucketPolicyOutput, error) {
	if f.getErr != nil {
		return nil, f.getErr
	}
	if f.policy == "" {
		return nil, &smithy.GenericAPIError{Code: "NoSuchBucketPolicy", Message: "The bucket policy does not exist"}
	}
	return &s3.GetBucketPolicyOutput{Policy: aws.String(f.policy)}, nil
}

func (f *fakeS3) PutBucketPolicy(_ context.Context, in *s3.PutBucketPolicyInput, _ ...func(*s3.Options)) (*s3.PutBucketPolicyOutput, error) {
	if f.putErr != nil {
		return nil, f.putErr
	}
	f.puts++
	f.lastPut = aws.ToString(in.Policy)
	f.policy = f.lastPut
	return &s3.PutBucketPolicyOutput{}, nil
}

// existing mirrors the stack's PhotosBucketPolicy (HTTPS-only deny).
const existing = `{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::bkt","arn:aws:s3:::bkt/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}`

func newHandler(f *fakeS3) *Handler {
	return &Handler{S3: f, Bucket: "bkt", BucketARN: "arn:aws:s3:::bkt", Prefixes: []string{"photos/", "trips/"}}
}

func alarmEvent(state string) events.SNSEvent {
	msg, _ := json.Marshal(map[string]string{"AlarmName": "picture-ware-download-tripwire", "NewStateValue": state, "NewStateReason": "Threshold Crossed"})
	return events.SNSEvent{Records: []events.SNSEventRecord{{SNS: events.SNSEntity{Subject: "ALARM", Message: string(msg)}}}}
}

type policyDoc struct {
	Version   string
	Statement []map[string]any
}

func parse(t *testing.T, s string) policyDoc {
	t.Helper()
	var d policyDoc
	if err := json.Unmarshal([]byte(s), &d); err != nil {
		t.Fatalf("policy is not valid JSON: %v\n%s", err, s)
	}
	return d
}

func TestHandleAlarmAddsDenyAndKeepsExistingStatements(t *testing.T) {
	f := &fakeS3{policy: existing}
	if err := newHandler(f).Handle(context.Background(), alarmEvent("ALARM")); err != nil {
		t.Fatal(err)
	}
	d := parse(t, f.lastPut)
	if d.Version != "2012-10-17" || len(d.Statement) != 2 {
		t.Fatalf("unexpected policy %+v", d)
	}
	if d.Statement[0]["Sid"] != "DenyInsecureTransport" || d.Statement[0]["Condition"] == nil {
		t.Fatalf("HTTPS-only statement not preserved: %+v", d.Statement[0])
	}
	deny := d.Statement[1]
	if deny["Sid"] != StatementID || deny["Effect"] != "Deny" || deny["Principal"] != "*" || deny["Action"] != "s3:GetObject" {
		t.Fatalf("unexpected deny statement %+v", deny)
	}
	res, _ := deny["Resource"].([]any)
	if len(res) != 2 || res[0] != "arn:aws:s3:::bkt/photos/*" || res[1] != "arn:aws:s3:::bkt/trips/*" {
		t.Fatalf("resources = %v", deny["Resource"])
	}
}

func TestHandleIsIdempotent(t *testing.T) {
	f := &fakeS3{policy: existing}
	h := newHandler(f)
	for i := 0; i < 3; i++ {
		if err := h.Handle(context.Background(), alarmEvent("ALARM")); err != nil {
			t.Fatal(err)
		}
	}
	if f.puts != 1 {
		t.Fatalf("puts = %d, want 1", f.puts)
	}
	if n := len(parse(t, f.policy).Statement); n != 2 {
		t.Fatalf("statements = %d, want 2", n)
	}
}

func TestHandleIgnoresOKNotification(t *testing.T) {
	f := &fakeS3{policy: existing}
	if err := newHandler(f).Handle(context.Background(), alarmEvent("OK")); err != nil {
		t.Fatal(err)
	}
	if f.puts != 0 {
		t.Fatalf("policy changed on OK notification")
	}
}

func TestHandleNonAlarmMessageTrips(t *testing.T) {
	f := &fakeS3{policy: existing}
	ev := events.SNSEvent{Records: []events.SNSEventRecord{{SNS: events.SNSEntity{Message: "manual test"}}}}
	if err := newHandler(f).Handle(context.Background(), ev); err != nil {
		t.Fatal(err)
	}
	if f.puts != 1 {
		t.Fatalf("puts = %d, want 1", f.puts)
	}
}

func TestHandleNoExistingPolicy(t *testing.T) {
	f := &fakeS3{}
	if err := newHandler(f).Handle(context.Background(), alarmEvent("ALARM")); err != nil {
		t.Fatal(err)
	}
	d := parse(t, f.lastPut)
	if d.Version != "2012-10-17" || len(d.Statement) != 1 || d.Statement[0]["Sid"] != StatementID {
		t.Fatalf("unexpected policy %+v", d)
	}
}

func TestHandleErrors(t *testing.T) {
	for name, f := range map[string]*fakeS3{
		"get fails":      {getErr: errors.New("denied")},
		"put fails":      {policy: existing, putErr: errors.New("denied")},
		"invalid policy": {policy: "not json"},
	} {
		t.Run(name, func(t *testing.T) {
			if err := newHandler(f).Handle(context.Background(), alarmEvent("ALARM")); err == nil {
				t.Fatal("want error")
			}
		})
	}
}

func TestAddDenySingleStatementObject(t *testing.T) {
	in := `{"Version":"2012-10-17","Id":"keep-me","Statement":{"Sid":"A","Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::bkt"}}`
	out, changed, err := AddDeny(in, map[string]any{"Sid": StatementID})
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	var doc map[string]any
	_ = json.Unmarshal([]byte(out), &doc)
	if doc["Id"] != "keep-me" {
		t.Fatalf("top-level field lost: %s", out)
	}
	if s, _ := doc["Statement"].([]any); len(s) != 2 {
		t.Fatalf("statements = %v", doc["Statement"])
	}
}
