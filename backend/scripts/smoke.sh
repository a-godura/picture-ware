#!/usr/bin/env bash
# End-to-end smoke test against the deployed stack:
#   validation errors -> create -> presigned POST upload -> processor marks
#   ready -> GET /photos lists it -> imageUrl downloads the same bytes;
#   wrong Content-Type and oversized uploads are rejected by S3.
# Test items/objects are deleted on exit.
set -euo pipefail

STACK="${STACK:-picture-ware}"
REGION="${REGION:-us-east-2}"
PROFILE="${PROFILE:-picture-ware}"
AWS=(aws --region "$REGION" --profile "$PROFILE")
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="$HERE/testdata/tiny.jpg"
TMP="$(mktemp -d)"
IDS=()

for bin in aws curl jq cmp; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done

output() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
API="$(output ApiUrl)"; BUCKET="$(output BucketName)"; TABLE="$(output TableName)"

cleanup() {
  for id in "${IDS[@]+"${IDS[@]}"}"; do
    "${AWS[@]}" dynamodb delete-item --table-name "$TABLE" --key "{\"id\":{\"S\":\"$id\"}}" >/dev/null || true
    "${AWS[@]}" s3 rm "s3://$BUCKET/photos/$id" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
  if [ ${#IDS[@]} -gt 0 ]; then echo "cleaned up ${#IDS[@]} test item(s)"; fi
}
trap cleanup EXIT

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }

# post_json BODY -> sets STATUS and writes body to $TMP/resp.json
post_json() {
  STATUS="$(curl -sS -o "$TMP/resp.json" -w '%{http_code}' -X POST "$API/photos" \
    -H 'Content-Type: application/json' -d "$1")"
}

# create_photo -> sets ID and writes the upload fields to $TMP/fields.txt
create_photo() {
  post_json '{"lat":37.7749,"lng":-122.4194,"takenAt":"2026-09-01T10:00:00Z","contentType":"image/jpeg"}'
  [ "$STATUS" = 201 ] || fail "POST /photos -> $STATUS $(cat "$TMP/resp.json")"
  ID="$(jq -r .id "$TMP/resp.json")"; IDS+=("$ID")
  UPLOAD_URL="$(jq -r .upload.url "$TMP/resp.json")"
  jq -r '.upload.fields | to_entries[] | "\(.key)=\(.value)"' "$TMP/resp.json" > "$TMP/fields.txt"
}

# upload FILE [CONTENT_TYPE_OVERRIDE] -> sets STATUS (000 if S3 dropped the connection)
upload() {
  local args=() line
  while IFS= read -r line; do
    if [ -n "${2:-}" ] && [[ "$line" == Content-Type=* ]]; then line="Content-Type=$2"; fi
    args+=(--form-string "$line")
  done < "$TMP/fields.txt"
  STATUS="$(curl -sS -o "$TMP/upload.xml" -w '%{http_code}' "${args[@]}" -F "file=@$1" "$UPLOAD_URL" || true)"
}

object_exists() { "${AWS[@]}" s3api head-object --bucket "$BUCKET" --key "photos/$1" >/dev/null 2>&1; }

echo "API: $API"

# 1. API validation
post_json '{"lat":37.7,"lng":-122.4,"contentType":"image/png"}'
[ "$STATUS" = 400 ] && jq -e .error "$TMP/resp.json" >/dev/null || fail "png contentType -> $STATUS"
pass "POST /photos contentType=image/png -> 400 $(jq -c . "$TMP/resp.json")"
post_json '{"lat":91,"lng":0,"contentType":"image/jpeg"}'
[ "$STATUS" = 400 ] || fail "lat=91 -> $STATUS"
pass "POST /photos lat=91 -> 400 $(jq -c . "$TMP/resp.json")"

# 2. Happy path
create_photo
pass "POST /photos -> 201 id=$ID"
upload "$IMG"
[ "$STATUS" = 204 ] || fail "upload -> $STATUS $(cat "$TMP/upload.xml")"
pass "presigned POST upload of $(wc -c < "$IMG" | tr -d ' ')-byte JPEG -> 204"

IMAGE_URL=""
for _ in $(seq 1 20); do
  curl -sS -o "$TMP/list.json" "$API/photos"
  IMAGE_URL="$(jq -r --arg id "$ID" '.photos[] | select(.id == $id) | .imageUrl' "$TMP/list.json")"
  [ -n "$IMAGE_URL" ] && break
  sleep 1.5
done
[ -n "$IMAGE_URL" ] || fail "photo $ID never appeared in GET /photos"
pass "GET /photos lists $ID: $(jq -c --arg id "$ID" '.photos[] | select(.id == $id) | del(.imageUrl)' "$TMP/list.json")"

STATUS="$(curl -sS -o "$TMP/download.jpg" -w '%{http_code}' "$IMAGE_URL")"
[ "$STATUS" = 200 ] && cmp -s "$IMG" "$TMP/download.jpg" || fail "imageUrl -> $STATUS / content mismatch"
pass "imageUrl -> 200, bytes identical to upload"

# 3. Rejected uploads (both against a fresh pending item)
create_photo
upload "$IMG" image/png
[ "$STATUS" = 403 ] || fail "wrong Content-Type upload -> $STATUS"
object_exists "$ID" && fail "object created despite wrong Content-Type"
pass "upload with Content-Type=image/png -> 403 $(grep -o '<Code>[^<]*' "$TMP/upload.xml" | cut -c7- || true)"

head -c $((15 * 1024 * 1024 + 1)) /dev/zero > "$TMP/big.jpg"
upload "$TMP/big.jpg"
case "$STATUS" in 2*) fail "oversized upload accepted ($STATUS)";; esac
object_exists "$ID" && fail "object created despite oversize"
pass "upload of 15 MiB + 1 byte -> $STATUS $(grep -o '<Code>[^<]*' "$TMP/upload.xml" 2>/dev/null | cut -c7- || true)"

curl -sS -o "$TMP/list.json" "$API/photos"
jq -e --arg id "$ID" 'all(.photos[]; .id != $id)' "$TMP/list.json" >/dev/null || fail "pending photo listed"
pass "pending photo $ID not listed"

echo "smoke test passed"
