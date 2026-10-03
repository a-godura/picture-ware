package photos

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// Presigning is purely local, so this exercises the real SDK with fake creds.
func newTestPresigner() *S3Presigner {
	client := s3.New(s3.Options{
		Region:      "us-east-2",
		Credentials: aws.NewCredentialsCache(credentials.NewStaticCredentialsProvider("AKIDTEST", "secret", "")),
	})
	return &S3Presigner{Client: s3.NewPresignClient(client), Bucket: "test-bucket", PostExpiry: 10 * time.Minute, GetExpiry: time.Hour}
}

func TestPresignUploadPolicy(t *testing.T) {
	up, err := newTestPresigner().PresignUpload(context.Background(), "photos/user-1/abc", "image/heic")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(up.URL, "test-bucket") {
		t.Fatalf("url %q does not reference bucket", up.URL)
	}
	if up.Fields["key"] != "photos/user-1/abc" || up.Fields["Content-Type"] != "image/heic" {
		t.Fatalf("fields = %v", up.Fields)
	}
	raw, err := base64.StdEncoding.DecodeString(up.Fields["policy"])
	if err != nil {
		t.Fatal(err)
	}
	var policy struct {
		Expiration string `json:"expiration"`
		Conditions []any  `json:"conditions"`
	}
	if err := json.Unmarshal(raw, &policy); err != nil {
		t.Fatal(err)
	}
	exp, err := time.Parse(time.RFC3339, policy.Expiration)
	if err != nil || time.Until(exp) > 11*time.Minute || time.Until(exp) < 9*time.Minute {
		t.Fatalf("expiration %q not ~10m out", policy.Expiration)
	}
	var haveKey, haveType, haveRange bool
	keyConds := 0
	for _, c := range policy.Conditions {
		switch c := c.(type) {
		case map[string]any:
			if k, ok := c["key"]; ok {
				keyConds++
				haveKey = k == "photos/user-1/abc"
			}
			if c["Content-Type"] == "image/heic" {
				haveType = true
			}
		case []any:
			if len(c) == 3 && c[0] == "content-length-range" && c[1] == float64(1) && c[2] == float64(MaxUploadBytes) {
				haveRange = true
			}
		}
	}
	if !haveKey || keyConds != 1 || !haveType || !haveRange {
		t.Fatalf("policy conditions missing (key=%v/%d type=%v range=%v): %s", haveKey, keyConds, haveType, haveRange, raw)
	}
}

func TestPresignGet(t *testing.T) {
	u, err := newTestPresigner().PresignGet(context.Background(), "photos/user-1/abc")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(u, "photos/user-1/abc") || !strings.Contains(u, "X-Amz-Expires=3600") {
		t.Fatalf("unexpected url %q", u)
	}
}
