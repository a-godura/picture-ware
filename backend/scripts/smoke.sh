#!/usr/bin/env bash
# End-to-end smoke test against the deployed stack:
#   creates two temporary Cognito users (A, B) and gets access tokens for them
#   via the test-only SmokeTestClient (IAM-authenticated admin APIs), then:
#   no/garbage/ID token -> 401; validation errors -> 400; A: create ->
#   presigned POST upload -> processor marks ready -> GET /photos lists it ->
#   imageUrl downloads the same bytes; B's GET /photos does not show A's
#   photo; wrong Content-Type and oversized uploads are rejected by S3.
# Test items, objects and both users are deleted on exit. Passwords and
# tokens are generated/held in a private temp dir and never printed.
set -euo pipefail

STACK="${STACK:-picture-ware}"
REGION="${REGION:-us-east-2}"
PROFILE="${PROFILE:-picture-ware}"
AWS=(aws --region "$REGION" --profile "$PROFILE")
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="$HERE/testdata/tiny.jpg"
umask 077
TMP="$(mktemp -d)"
KEYS=()  # "<userId>/<id>" of created photo records
USERS=() # Cognito usernames to delete

for bin in aws curl jq cmp openssl; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done

output() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
API="$(output ApiUrl)"; BUCKET="$(output BucketName)"; TABLE="$(output TableName)"
POOL="$(output UserPoolId)"; CLIENT="$(output SmokeTestClientId)"

cleanup() {
  local k uid id
  for k in "${KEYS[@]+"${KEYS[@]}"}"; do
    uid="${k%%/*}"; id="${k#*/}"
    "${AWS[@]}" dynamodb delete-item --table-name "$TABLE" \
      --key "{\"userId\":{\"S\":\"$uid\"},\"id\":{\"S\":\"$id\"}}" >/dev/null || true
    "${AWS[@]}" s3 rm "s3://$BUCKET/photos/$uid/$id" >/dev/null 2>&1 || true
  done
  for u in "${USERS[@]+"${USERS[@]}"}"; do
    "${AWS[@]}" cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$u" >/dev/null || true
  done
  rm -rf "$TMP"
  echo "cleaned up ${#KEYS[@]} test item(s) and ${#USERS[@]} test user(s)"
}
trap cleanup EXIT

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }

# new_user NAME -> creates a confirmed user with a random password, writes
# Authorization header files $TMP/NAME.auth (access token) and
# $TMP/NAME.idauth (ID token), and sets SUB.
new_user() {
  local name="$1" email pw
  email="pw-smoke-$name-$(openssl rand -hex 6)@example.com"
  pw="Pw-$(openssl rand -base64 24 | tr -d '/+=')"
  SUB="$("${AWS[@]}" cognito-idp admin-create-user --user-pool-id "$POOL" --username "$email" \
    --message-action SUPPRESS --user-attributes Name=email,Value="$email" Name=email_verified,Value=true \
    --query "User.Attributes[?Name=='sub'].Value | [0]" --output text)"
  USERS+=("$email")
  # Secrets go through --cli-input-json files so they never appear in argv.
  jq -n --arg p "$POOL" --arg u "$email" --arg pw "$pw" \
    '{UserPoolId:$p, Username:$u, Password:$pw, Permanent:true}' > "$TMP/$name.setpw.json"
  "${AWS[@]}" cognito-idp admin-set-user-password --cli-input-json "file://$TMP/$name.setpw.json"
  jq -n --arg p "$POOL" --arg c "$CLIENT" --arg u "$email" --arg pw "$pw" \
    '{UserPoolId:$p, ClientId:$c, AuthFlow:"ADMIN_USER_PASSWORD_AUTH", AuthParameters:{USERNAME:$u, PASSWORD:$pw}}' \
    > "$TMP/$name.auth.json"
  "${AWS[@]}" cognito-idp admin-initiate-auth --cli-input-json "file://$TMP/$name.auth.json" \
    --output json > "$TMP/$name.tokens.json"
  rm -f "$TMP/$name.setpw.json" "$TMP/$name.auth.json"
  printf 'Authorization: Bearer %s\n' "$(jq -r .AuthenticationResult.AccessToken "$TMP/$name.tokens.json")" > "$TMP/$name.auth"
  printf 'Authorization: Bearer %s\n' "$(jq -r .AuthenticationResult.IdToken "$TMP/$name.tokens.json")" > "$TMP/$name.idauth"
  rm -f "$TMP/$name.tokens.json"
}

# api METHOD AUTHFILE [BODY] -> sets STATUS, body in $TMP/resp.json.
# AUTHFILE is a curl header file (or /dev/null for no Authorization header).
api() {
  local args=(-sS -o "$TMP/resp.json" -w '%{http_code}' -X "$1" -H "@$2")
  if [ -n "${3:-}" ]; then args+=(-H 'Content-Type: application/json' -d "$3"); fi
  STATUS="$(curl "${args[@]}" "$API/photos")"
}

# create_photo AUTHFILE USERID -> sets ID and writes the upload fields to $TMP/fields.txt
create_photo() {
  api POST "$1" '{"lat":37.7749,"lng":-122.4194,"takenAt":"2026-09-01T10:00:00Z","contentType":"image/jpeg"}'
  [ "$STATUS" = 201 ] || fail "POST /photos -> $STATUS $(cat "$TMP/resp.json")"
  ID="$(jq -r .id "$TMP/resp.json")"; KEYS+=("$2/$ID")
  [ "$(jq -r '.upload.fields.key' "$TMP/resp.json")" = "photos/$2/$ID" ] || fail "upload key not photos/<sub>/<id>"
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

# 0. Users and tokens
new_user a; SUB_A="$SUB"
new_user b; SUB_B="$SUB"
pass "created temporary users A and B, got access tokens via SmokeTestClient"

# 1. Authentication
api GET /dev/null
[ "$STATUS" = 401 ] || fail "GET /photos without token -> $STATUS"
pass "GET /photos without token -> 401 $(jq -c . "$TMP/resp.json")"
api POST /dev/null '{"lat":1,"lng":1,"contentType":"image/jpeg"}'
[ "$STATUS" = 401 ] || fail "POST /photos without token -> $STATUS"
pass "POST /photos without token -> 401"
printf 'Authorization: Bearer not.a.jwt\n' > "$TMP/garbage.auth"
api GET "$TMP/garbage.auth"
[ "$STATUS" = 401 ] || fail "GET /photos with garbage token -> $STATUS"
pass "GET /photos with garbage token -> 401 $(jq -c . "$TMP/resp.json")"
api GET "$TMP/a.idauth"
[ "$STATUS" = 401 ] || fail "GET /photos with ID token -> $STATUS"
pass "GET /photos with ID token (not access token) -> 401 $(jq -c . "$TMP/resp.json")"

# 2. API validation (authenticated)
api POST "$TMP/a.auth" '{"lat":37.7,"lng":-122.4,"contentType":"image/png"}'
[ "$STATUS" = 400 ] && jq -e .error "$TMP/resp.json" >/dev/null || fail "png contentType -> $STATUS"
pass "POST /photos contentType=image/png -> 400 $(jq -c . "$TMP/resp.json")"
api POST "$TMP/a.auth" '{"lat":91,"lng":0,"contentType":"image/jpeg"}'
[ "$STATUS" = 400 ] || fail "lat=91 -> $STATUS"
pass "POST /photos lat=91 -> 400 $(jq -c . "$TMP/resp.json")"

# 3. Happy path for user A
create_photo "$TMP/a.auth" "$SUB_A"
A_ID="$ID"
pass "A: POST /photos -> 201 id=$ID key=photos/<subA>/<id>"
upload "$IMG"
[ "$STATUS" = 204 ] || fail "upload -> $STATUS $(cat "$TMP/upload.xml")"
pass "A: presigned POST upload of $(wc -c < "$IMG" | tr -d ' ')-byte JPEG -> 204"

IMAGE_URL=""
for _ in $(seq 1 20); do
  api GET "$TMP/a.auth"
  [ "$STATUS" = 200 ] || fail "A: GET /photos -> $STATUS"
  IMAGE_URL="$(jq -r --arg id "$ID" '.photos[] | select(.id == $id) | .imageUrl' "$TMP/resp.json")"
  [ -n "$IMAGE_URL" ] && break
  sleep 1.5
done
[ -n "$IMAGE_URL" ] || fail "photo $ID never appeared in A's GET /photos"
pass "A: GET /photos lists $ID: $(jq -c --arg id "$ID" '.photos[] | select(.id == $id) | del(.imageUrl)' "$TMP/resp.json")"

STATUS="$(curl -sS -o "$TMP/download.jpg" -w '%{http_code}' "$IMAGE_URL")"
[ "$STATUS" = 200 ] && cmp -s "$IMG" "$TMP/download.jpg" || fail "imageUrl -> $STATUS / content mismatch"
pass "A: imageUrl -> 200, bytes identical to upload"

# 4. Isolation: B must not see A's photo
api GET "$TMP/b.auth"
[ "$STATUS" = 200 ] || fail "B: GET /photos -> $STATUS"
jq -e --arg id "$A_ID" 'all(.photos[]; .id != $id)' "$TMP/resp.json" >/dev/null || fail "B can see A's photo"
pass "B: GET /photos -> 200 with $(jq '.photos | length' "$TMP/resp.json") photo(s); A's $A_ID not visible"

# 5. Rejected uploads (both against a fresh pending item of A's)
create_photo "$TMP/a.auth" "$SUB_A"
upload "$IMG" image/png
[ "$STATUS" = 403 ] || fail "wrong Content-Type upload -> $STATUS"
object_exists "$SUB_A/$ID" && fail "object created despite wrong Content-Type"
pass "upload with Content-Type=image/png -> 403 $(grep -o '<Code>[^<]*' "$TMP/upload.xml" | cut -c7- || true)"

head -c $((15 * 1024 * 1024 + 1)) /dev/zero > "$TMP/big.jpg"
upload "$TMP/big.jpg"
case "$STATUS" in 2*) fail "oversized upload accepted ($STATUS)";; esac
object_exists "$SUB_A/$ID" && fail "object created despite oversize"
pass "upload of 15 MiB + 1 byte -> $STATUS $(grep -o '<Code>[^<]*' "$TMP/upload.xml" 2>/dev/null | cut -c7- || true)"

api GET "$TMP/a.auth"
jq -e --arg id "$ID" 'all(.photos[]; .id != $id)' "$TMP/resp.json" >/dev/null || fail "pending photo listed"
pass "pending photo $ID not listed"

# B cannot write into A's prefix: B's own upload slot pins B's key.
create_photo "$TMP/b.auth" "$SUB_B"
sed -i.bak "s|^key=.*|key=photos/$SUB_A/$ID|" "$TMP/fields.txt"
upload "$IMG"
[ "$STATUS" = 403 ] || fail "B uploading into A's key -> $STATUS"
object_exists "$SUB_A/$ID" && fail "B wrote into A's prefix"
pass "B: upload with key rewritten to A's prefix -> 403"

echo "smoke test passed"
