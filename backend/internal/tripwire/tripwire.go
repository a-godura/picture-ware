// Package tripwire blocks photo downloads when S3 download volume is abnormal.
//
// Presigned GET URLs are served by S3 directly, so the API throttle does not
// limit them and the budget kill switch only reacts after billing data
// arrives (8-24 h). A CloudWatch alarm on the bucket's BytesDownloaded request
// metric publishes to SNS within minutes; this handler then adds a Deny on
// s3:GetObject for the protected prefixes to the bucket policy. The Deny stays
// until someone removes it (scripts/tripwire-reset.sh).
package tripwire

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
)

// StatementID marks the statement this package adds; the reset script removes
// the statement with this Sid.
const StatementID = "TripwireDenyDownloads"

// PolicyClient is the subset of the S3 client used.
type PolicyClient interface {
	GetBucketPolicy(ctx context.Context, in *s3.GetBucketPolicyInput, opts ...func(*s3.Options)) (*s3.GetBucketPolicyOutput, error)
	PutBucketPolicy(ctx context.Context, in *s3.PutBucketPolicyInput, opts ...func(*s3.Options)) (*s3.PutBucketPolicyOutput, error)
}

// Handler applies the download block.
type Handler struct {
	S3        PolicyClient
	Bucket    string
	BucketARN string   // e.g. arn:aws:s3:::my-bucket
	Prefixes  []string // object key prefixes to block, e.g. "photos/"
}

// alarmMessage is the part of a CloudWatch alarm SNS notification we read.
type alarmMessage struct {
	AlarmName      string `json:"AlarmName"`
	NewStateValue  string `json:"NewStateValue"`
	NewStateReason string `json:"NewStateReason"`
}

// Handle is invoked by the tripwire SNS topic. Messages that are CloudWatch
// alarm notifications for a state other than ALARM are ignored; anything else
// (including a non-JSON test message) trips the wire, erring on the side of
// blocking.
func (h *Handler) Handle(ctx context.Context, ev events.SNSEvent) error {
	trip := false
	for _, r := range ev.Records {
		var m alarmMessage
		if err := json.Unmarshal([]byte(r.SNS.Message), &m); err == nil && m.NewStateValue != "" && m.NewStateValue != "ALARM" {
			slog.InfoContext(ctx, "tripwire ignoring non-ALARM notification", "alarm", m.AlarmName, "state", m.NewStateValue)
			continue
		}
		slog.WarnContext(ctx, "download tripwire triggered", "alarm", m.AlarmName, "reason", m.NewStateReason, "subject", r.SNS.Subject)
		trip = true
	}
	if !trip {
		return nil
	}
	added, err := h.Block(ctx)
	if err != nil {
		return err
	}
	if added {
		slog.WarnContext(ctx, "downloads blocked", "bucket", h.Bucket, "prefixes", h.Prefixes)
	} else {
		slog.InfoContext(ctx, "downloads already blocked", "bucket", h.Bucket)
	}
	return nil
}

// Block adds the Deny statement to the bucket policy, keeping every existing
// statement. It reports whether the policy changed (false when already blocked).
func (h *Handler) Block(ctx context.Context) (bool, error) {
	if len(h.Prefixes) == 0 {
		return false, errors.New("tripwire: no prefixes configured")
	}
	current, err := h.getPolicy(ctx)
	if err != nil {
		return false, err
	}
	updated, changed, err := AddDeny(current, h.denyStatement())
	if err != nil || !changed {
		return false, err
	}
	if _, err := h.S3.PutBucketPolicy(ctx, &s3.PutBucketPolicyInput{
		Bucket: aws.String(h.Bucket),
		Policy: aws.String(updated),
	}); err != nil {
		return false, fmt.Errorf("put bucket policy: %w", err)
	}
	return true, nil
}

func (h *Handler) getPolicy(ctx context.Context) (string, error) {
	out, err := h.S3.GetBucketPolicy(ctx, &s3.GetBucketPolicyInput{Bucket: aws.String(h.Bucket)})
	if err != nil {
		var apiErr smithy.APIError
		if errors.As(err, &apiErr) && apiErr.ErrorCode() == "NoSuchBucketPolicy" {
			return "", nil
		}
		return "", fmt.Errorf("get bucket policy: %w", err)
	}
	return aws.ToString(out.Policy), nil
}

func (h *Handler) denyStatement() map[string]any {
	resources := make([]any, 0, len(h.Prefixes))
	for _, p := range h.Prefixes {
		resources = append(resources, h.BucketARN+"/"+p+"*")
	}
	return map[string]any{
		"Sid":       StatementID,
		"Effect":    "Deny",
		"Principal": "*",
		"Action":    "s3:GetObject",
		"Resource":  resources,
	}
}

// AddDeny returns policy with stmt appended, unless a statement with the same
// Sid already exists (then changed is false). Unknown fields and the order of
// existing statements are preserved; an empty policy starts a new document.
func AddDeny(policy string, stmt map[string]any) (string, bool, error) {
	doc := map[string]any{}
	if policy != "" {
		if err := json.Unmarshal([]byte(policy), &doc); err != nil {
			return "", false, fmt.Errorf("parse bucket policy: %w", err)
		}
	}
	if _, ok := doc["Version"]; !ok {
		doc["Version"] = "2012-10-17"
	}
	var stmts []any
	switch s := doc["Statement"].(type) {
	case nil:
	case []any:
		stmts = s
	case map[string]any: // a single statement may be written as an object
		stmts = []any{s}
	default:
		return "", false, fmt.Errorf("parse bucket policy: unexpected Statement type %T", s)
	}
	for _, s := range stmts {
		if m, ok := s.(map[string]any); ok && m["Sid"] == stmt["Sid"] {
			return policy, false, nil
		}
	}
	doc["Statement"] = append(stmts, stmt)
	b, err := json.Marshal(doc)
	if err != nil {
		return "", false, err
	}
	return string(b), true, nil
}
