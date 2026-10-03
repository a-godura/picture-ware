#!/usr/bin/env bash
# End-to-end smoke test against the deployed stack:
#   creates two temporary Cognito users (A, B) and gets access tokens for them
#   via the test-only SmokeTestClient (IAM-authenticated admin APIs), then:
#   no/garbage/ID token -> 401; validation errors -> 400; A creates a trip ->
#   it's in A's GET /trips; A uploads a photo (presigned POST) -> processor
#   marks it ready -> GET /trips/{id}/photos lists it -> imageUrl downloads the
#   same bytes; B (not a member) gets 404 for the trip and its photos and
#   doesn't see it in GET /trips; wrong Content-Type and oversized uploads are
#   rejected by S3; delete rules hold; members: A shares an invite link (the
#   public landing page opens the app), B previews and joins with the code,
#   sees A's photos, leaves, rejoins, is removed by A (which rotates the
#   invite, so B's old code stops working); the owner can't leave; a rotated
#   code stops working.
# Test trips (all their items and objects) and both users are deleted on exit. Passwords and
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
TRIPS=()   # "<tripId>/<creatorSub>" of created trips
USERS=()   # Cognito usernames to delete
SUBS=()    # their subs (for "my trips" entries left by joining)
INVITES=() # invite codes handed out

for bin in aws curl jq cmp openssl; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done

output() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
API="$(output ApiUrl)"; BUCKET="$(output BucketName)"; TABLE="$(output TableName)"
POOL="$(output UserPoolId)"; CLIENT="$(output SmokeTestClientId)"

delete_key() {
  "${AWS[@]}" dynamodb delete-item --table-name "$TABLE" \
    --key "{\"PK\":{\"S\":\"$1\"},\"SK\":{\"S\":\"$2\"}}" >/dev/null || true
}

cleanup() {
  local t trip creator sk sub code
  for t in "${TRIPS[@]+"${TRIPS[@]}"}"; do
    trip="${t%%/*}"; creator="${t#*/}"
    for sk in $("${AWS[@]}" dynamodb query --table-name "$TABLE" \
      --key-condition-expression "PK = :pk" \
      --expression-attribute-values "{\":pk\":{\"S\":\"TRIP#$trip\"}}" \
      --query 'Items[].SK.S' --output text 2>/dev/null); do
      delete_key "TRIP#$trip" "$sk"
    done
    delete_key "USER#$creator" "TRIP#$trip"
    for sub in "${SUBS[@]+"${SUBS[@]}"}"; do delete_key "USER#$sub" "TRIP#$trip"; done
    "${AWS[@]}" s3 rm "s3://$BUCKET/trips/$trip/" --recursive >/dev/null 2>&1 || true
  done
  for code in "${INVITES[@]+"${INVITES[@]}"}"; do delete_key "INVITE#$code" META; done
  for u in "${USERS[@]+"${USERS[@]}"}"; do
    "${AWS[@]}" cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$u" >/dev/null || true
  done
  rm -rf "$TMP"
  echo "cleaned up ${#TRIPS[@]} test trip(s) and ${#USERS[@]} test user(s)"
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
  USERS+=("$email"); SUBS+=("$SUB")
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

# api METHOD AUTHFILE PATH [BODY] -> sets STATUS, body in $TMP/resp.json.
# AUTHFILE is a curl header file (or /dev/null for no Authorization header).
api() {
  local args=(-sS -o "$TMP/resp.json" -w '%{http_code}' -X "$1" -H "@$2")
  if [ -n "${4:-}" ]; then args+=(-H 'Content-Type: application/json' -d "$4"); fi
  STATUS="$(curl "${args[@]}" "$API$3")"
}

# create_trip AUTHFILE CREATOR_SUB NAME -> sets TRIP
create_trip() {
  api POST "$1" /trips "{\"name\":\"$3\",\"startDate\":\"2026-10-01\",\"endDate\":\"2026-10-07\"}"
  [ "$STATUS" = 201 ] || fail "POST /trips -> $STATUS $(cat "$TMP/resp.json")"
  TRIP="$(jq -r .id "$TMP/resp.json")"; TRIPS+=("$TRIP/$2")
}

# create_photo AUTHFILE TRIP -> sets ID and writes the upload fields to $TMP/fields.txt
create_photo() {
  api POST "$1" "/trips/$2/photos" '{"lat":37.7749,"lng":-122.4194,"takenAt":"2026-09-01T10:00:00Z","contentType":"image/jpeg"}'
  [ "$STATUS" = 201 ] || fail "POST /trips/$2/photos -> $STATUS $(cat "$TMP/resp.json")"
  ID="$(jq -r .id "$TMP/resp.json")"
  [ "$(jq -r '.upload.fields.key' "$TMP/resp.json")" = "trips/$2/$ID" ] || fail "upload key not trips/<trip>/<id>"
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

object_exists() { "${AWS[@]}" s3api head-object --bucket "$BUCKET" --key "trips/$1" >/dev/null 2>&1; }

echo "API: $API"

# 0. Users and tokens
new_user a; SUB_A="$SUB"
new_user b; SUB_B="$SUB"
pass "created temporary users A and B, got access tokens via SmokeTestClient"

# 1. Authentication
api GET /dev/null /trips
[ "$STATUS" = 401 ] || fail "GET /trips without token -> $STATUS"
pass "GET /trips without token -> 401 $(jq -c . "$TMP/resp.json")"
api POST /dev/null /trips '{"name":"x","startDate":"2026-10-01"}'
[ "$STATUS" = 401 ] || fail "POST /trips without token -> $STATUS"
pass "POST /trips without token -> 401"
printf 'Authorization: Bearer not.a.jwt\n' > "$TMP/garbage.auth"
api GET "$TMP/garbage.auth" /trips
[ "$STATUS" = 401 ] || fail "GET /trips with garbage token -> $STATUS"
pass "GET /trips with garbage token -> 401 $(jq -c . "$TMP/resp.json")"
api GET "$TMP/a.idauth" /trips
[ "$STATUS" = 401 ] || fail "GET /trips with ID token -> $STATUS"
pass "GET /trips with ID token (not access token) -> 401 $(jq -c . "$TMP/resp.json")"

# 2. Legacy /photos routes still answer (for the currently shipped app)
api GET "$TMP/a.auth" /photos
[ "$STATUS" = 200 ] && jq -e '.photos | type == "array"' "$TMP/resp.json" >/dev/null || fail "legacy GET /photos -> $STATUS"
pass "legacy GET /photos -> 200"

# 3. Trips
api POST "$TMP/a.auth" /trips '{"name":"   ","startDate":"2026-10-01"}'
[ "$STATUS" = 400 ] || fail "blank trip name -> $STATUS"
pass "POST /trips blank name -> 400 $(jq -c . "$TMP/resp.json")"
api POST "$TMP/a.auth" /trips '{"name":"x","startDate":"2026-10-02","endDate":"2026-10-01"}'
[ "$STATUS" = 400 ] || fail "end before start -> $STATUS"
pass "POST /trips end before start -> 400 $(jq -c . "$TMP/resp.json")"
create_trip "$TMP/a.auth" "$SUB_A" "Smoke test trip"
A_TRIP="$TRIP"
pass "A: POST /trips -> 201 $(jq -c . "$TMP/resp.json")"
api GET "$TMP/a.auth" /trips
jq -e --arg t "$A_TRIP" 'any(.trips[]; .id == $t)' "$TMP/resp.json" >/dev/null || fail "A's trip not in GET /trips"
pass "A: GET /trips includes it"
api GET "$TMP/a.auth" "/trips/$A_TRIP"
[ "$STATUS" = 200 ] || fail "A: GET /trips/{id} -> $STATUS"
pass "A: GET /trips/{id} -> 200"

# 4. Photo validation (authenticated member)
api POST "$TMP/a.auth" "/trips/$A_TRIP/photos" '{"lat":37.7,"lng":-122.4,"contentType":"image/png"}'
[ "$STATUS" = 400 ] && jq -e .error "$TMP/resp.json" >/dev/null || fail "png contentType -> $STATUS"
pass "POST photo contentType=image/png -> 400 $(jq -c . "$TMP/resp.json")"
api POST "$TMP/a.auth" "/trips/$A_TRIP/photos" '{"lat":91,"lng":0,"contentType":"image/jpeg"}'
[ "$STATUS" = 400 ] || fail "lat=91 -> $STATUS"
pass "POST photo lat=91 -> 400 $(jq -c . "$TMP/resp.json")"

# 5. Happy path: A uploads into the trip
create_photo "$TMP/a.auth" "$A_TRIP"
A_ID="$ID"
pass "A: POST /trips/{id}/photos -> 201 id=$ID key=trips/<trip>/<id>"
upload "$IMG"
[ "$STATUS" = 204 ] || fail "upload -> $STATUS $(cat "$TMP/upload.xml")"
pass "A: presigned POST upload of $(wc -c < "$IMG" | tr -d ' ')-byte JPEG -> 204"

IMAGE_URL=""
for _ in $(seq 1 20); do
  api GET "$TMP/a.auth" "/trips/$A_TRIP/photos"
  [ "$STATUS" = 200 ] || fail "A: GET photos -> $STATUS"
  IMAGE_URL="$(jq -r --arg id "$ID" '.photos[] | select(.id == $id) | .imageUrl' "$TMP/resp.json")"
  [ -n "$IMAGE_URL" ] && break
  sleep 1.5
done
[ -n "$IMAGE_URL" ] || fail "photo $ID never appeared in the trip"
jq -e --arg id "$ID" --arg u "$SUB_A" '.photos[] | select(.id == $id) | .uploaderId == $u' "$TMP/resp.json" >/dev/null || fail "uploaderId wrong"
pass "A: GET /trips/{id}/photos lists $ID: $(jq -c --arg id "$ID" '.photos[] | select(.id == $id) | del(.imageUrl, .uploaderId)' "$TMP/resp.json")"

STATUS="$(curl -sS -o "$TMP/download.jpg" -w '%{http_code}' "$IMAGE_URL")"
[ "$STATUS" = 200 ] && cmp -s "$IMG" "$TMP/download.jpg" || fail "imageUrl -> $STATUS / content mismatch"
pass "A: imageUrl -> 200, bytes identical to upload"

# 6. Isolation: B is not a member of A's trip
api GET "$TMP/b.auth" /trips
[ "$STATUS" = 200 ] || fail "B: GET /trips -> $STATUS"
jq -e --arg t "$A_TRIP" 'all(.trips[]; .id != $t)' "$TMP/resp.json" >/dev/null || fail "B sees A's trip"
pass "B: GET /trips -> 200, A's trip not listed"
for path in "/trips/$A_TRIP" "/trips/$A_TRIP/photos"; do
  api GET "$TMP/b.auth" "$path"
  [ "$STATUS" = 404 ] || fail "B: GET $path -> $STATUS"
done
pass "B: GET A's trip and its photos -> 404"
api POST "$TMP/b.auth" "/trips/$A_TRIP/photos" '{"lat":1,"lng":1,"contentType":"image/jpeg"}'
[ "$STATUS" = 404 ] || fail "B: POST photo into A's trip -> $STATUS"
pass "B: POST photo into A's trip -> 404"

# 7. Rejected uploads (against a fresh pending photo in A's trip)
create_photo "$TMP/a.auth" "$A_TRIP"
upload "$IMG" image/png
[ "$STATUS" = 403 ] || fail "wrong Content-Type upload -> $STATUS"
object_exists "$A_TRIP/$ID" && fail "object created despite wrong Content-Type"
pass "upload with Content-Type=image/png -> 403 $(grep -o '<Code>[^<]*' "$TMP/upload.xml" | cut -c7- || true)"

head -c $((15 * 1024 * 1024 + 1)) /dev/zero > "$TMP/big.jpg"
upload "$TMP/big.jpg"
case "$STATUS" in 2*) fail "oversized upload accepted ($STATUS)";; esac
object_exists "$A_TRIP/$ID" && fail "object created despite oversize"
pass "upload of 15 MiB + 1 byte -> $STATUS $(grep -o '<Code>[^<]*' "$TMP/upload.xml" 2>/dev/null | cut -c7- || true)"

api GET "$TMP/a.auth" "/trips/$A_TRIP/photos"
jq -e --arg id "$ID" 'all(.photos[]; .id != $id)' "$TMP/resp.json" >/dev/null || fail "pending photo listed"
pass "pending photo $ID not listed"

# B can't write into A's trip prefix: B's own upload slot pins B's trip key.
create_trip "$TMP/b.auth" "$SUB_B" "B's trip"
create_photo "$TMP/b.auth" "$TRIP"
sed -i.bak "s|^key=.*|key=trips/$A_TRIP/$ID|" "$TMP/fields.txt"
upload "$IMG"
[ "$STATUS" = 403 ] || fail "B uploading into A's trip key -> $STATUS"
object_exists "$A_TRIP/$ID" && fail "B wrote into A's trip prefix"
pass "B: upload with key rewritten to A's trip -> 403"

# 8. Delete
del() { STATUS="$(curl -sS -o "$TMP/resp.json" -w '%{http_code}' -X DELETE -H "@$1" "$API/trips/$2/photos/$3")"; }
del /dev/null "$A_TRIP" "$A_ID"
[ "$STATUS" = 401 ] || fail "DELETE without token -> $STATUS"
pass "DELETE photo without token -> 401"
del "$TMP/b.auth" "$A_TRIP" "$A_ID"
[ "$STATUS" = 404 ] || fail "B deleting A's photo -> $STATUS"
object_exists "$A_TRIP/$A_ID" || fail "B's delete removed A's object"
pass "B: DELETE A's photo -> 404, A's object still there"
del "$TMP/a.auth" "$A_TRIP" "$A_ID"
[ "$STATUS" = 204 ] || fail "A: DELETE -> $STATUS $(cat "$TMP/resp.json")"
object_exists "$A_TRIP/$A_ID" && fail "object still exists after delete"
api GET "$TMP/a.auth" "/trips/$A_TRIP/photos"
jq -e --arg id "$A_ID" 'all(.photos[]; .id != $id)' "$TMP/resp.json" >/dev/null || fail "deleted photo still listed"
pass "A: DELETE photo -> 204, object gone, not listed"
del "$TMP/a.auth" "$A_TRIP" "$A_ID"
[ "$STATUS" = 404 ] || fail "repeat DELETE -> $STATUS"
pass "A: repeat DELETE -> 404"

# 9. Members and invites
# wait_listed AUTHFILE TRIP ID -> waits until the photo is listed in the trip
wait_listed() {
  for _ in $(seq 1 20); do
    api GET "$1" "/trips/$2/photos"
    [ "$STATUS" = 200 ] || fail "GET /trips/$2/photos -> $STATUS"
    jq -e --arg id "$3" 'any(.photos[]; .id == $id)' "$TMP/resp.json" >/dev/null && return 0
    sleep 1.5
  done
  fail "photo $3 never appeared in trip $2"
}
create_photo "$TMP/a.auth" "$A_TRIP"; A_ID="$ID"
upload "$IMG"
[ "$STATUS" = 204 ] || fail "upload -> $STATUS"
wait_listed "$TMP/a.auth" "$A_TRIP" "$A_ID"
pass "A: uploaded another photo $A_ID"

api POST "$TMP/a.auth" "/trips/$A_TRIP/invite"
[ "$STATUS" = 200 ] || fail "A: POST invite -> $STATUS $(cat "$TMP/resp.json")"
CODE="$(jq -r .code "$TMP/resp.json")"; INVITES+=("$CODE")
LINK="$(jq -r .url "$TMP/resp.json")"
[[ "$CODE" =~ ^[a-z2-7]{26}$ ]] || fail "invite code $CODE malformed"
[ "$LINK" = "$API/j/$CODE" ] || fail "invite url $LINK"
[ "$(jq -r .appUrl "$TMP/resp.json")" = "picture-ware://join/$CODE" ] || fail "invite appUrl"
api POST "$TMP/a.auth" "/trips/$A_TRIP/invite"
[ "$STATUS" = 200 ] && [ "$(jq -r .code "$TMP/resp.json")" = "$CODE" ] || fail "second POST invite changed the code"
pass "A: POST /trips/{id}/invite -> 200, same code on repeat, url=<api>/j/<code>"

STATUS="$(curl -sS -o "$TMP/landing.html" -D "$TMP/landing.h" -w '%{http_code}' "$LINK")"
[ "$STATUS" = 200 ] && grep -qi '^content-type: text/html' "$TMP/landing.h" \
  && grep -q "picture-ware://join/$CODE" "$TMP/landing.html" || fail "landing page -> $STATUS"
grep -q "Smoke test trip" "$TMP/landing.html" && fail "landing page leaks the trip name"
pass "GET /j/<code> without a token -> 200 text/html with the app link, no trip data"
STATUS="$(curl -sS -o /dev/null -w '%{http_code}' "$API/j/not-a-code")"
[ "$STATUS" = 404 ] || fail "malformed landing code -> $STATUS"
pass "GET /j/not-a-code -> 404"

api GET "$TMP/b.auth" "/invites/$CODE"
[ "$STATUS" = 200 ] || fail "B: preview -> $STATUS $(cat "$TMP/resp.json")"
jq -e --arg t "$A_TRIP" '.trip.id == $t and .memberCount == 1 and .alreadyMember == false and (.ownerName | startswith("pw-smoke-a-"))' \
  "$TMP/resp.json" >/dev/null || fail "B: preview body $(cat "$TMP/resp.json")"
pass "B: GET /invites/{code} -> 200 $(jq -c 'del(.code)' "$TMP/resp.json")"

accept() { api POST "$1" "/invites/$2/accept"; }
accept "$TMP/b.auth" "$CODE"
[ "$STATUS" = 200 ] && jq -e --arg t "$A_TRIP" '.id == $t' "$TMP/resp.json" >/dev/null || fail "B: accept -> $STATUS $(cat "$TMP/resp.json")"
accept "$TMP/b.auth" "$CODE"
[ "$STATUS" = 200 ] || fail "B: repeat accept -> $STATUS"
pass "B: POST /invites/{code}/accept -> 200 (and again -> 200)"
api GET "$TMP/b.auth" /trips
jq -e --arg t "$A_TRIP" 'any(.trips[]; .id == $t)' "$TMP/resp.json" >/dev/null || fail "B doesn't list A's trip after joining"
wait_listed "$TMP/b.auth" "$A_TRIP" "$A_ID"
pass "B: A's trip is in GET /trips and B sees A's photo"

api GET "$TMP/b.auth" "/trips/$A_TRIP/members"
[ "$STATUS" = 200 ] || fail "B: members -> $STATUS"
jq -e --arg a "$SUB_A" --arg b "$SUB_B" '[.members[] | .userId + ":" + .role] == [$a + ":owner", $b + ":member"]' \
  "$TMP/resp.json" >/dev/null || fail "members $(cat "$TMP/resp.json")"
jq -e 'all(.members[]; (.name // "") | contains("@") | not)' "$TMP/resp.json" >/dev/null || fail "members list shows an email"
pass "B: GET /trips/{id}/members -> owner A, member B, no emails"

api POST "$TMP/b.auth" "/trips/$A_TRIP/invite"
[ "$STATUS" = 200 ] && [ "$(jq -r .code "$TMP/resp.json")" = "$CODE" ] || fail "B: POST invite -> $STATUS"
pass "B (member): POST invite -> 200, the same link to share"
api POST "$TMP/b.auth" "/trips/$A_TRIP/invite/rotate"
[ "$STATUS" = 403 ] || fail "B: rotate -> $STATUS"
pass "B (member): rotate -> 403"

member_del() { api DELETE "$1" "/trips/$A_TRIP/members/$2"; }
member_del "$TMP/b.auth" "$SUB_B"
[ "$STATUS" = 204 ] || fail "B: leave -> $STATUS $(cat "$TMP/resp.json")"
api GET "$TMP/b.auth" "/trips/$A_TRIP/photos"
[ "$STATUS" = 404 ] || fail "B after leaving: photos -> $STATUS"
api GET "$TMP/b.auth" /trips
jq -e --arg t "$A_TRIP" 'all(.trips[]; .id != $t)' "$TMP/resp.json" >/dev/null || fail "B still lists A's trip"
pass "B: leave -> 204, then A's trip is 404 and not listed"

accept "$TMP/b.auth" "$CODE"
[ "$STATUS" = 200 ] || fail "B: rejoin -> $STATUS"
member_del "$TMP/a.auth" "$SUB_B"
[ "$STATUS" = 204 ] || fail "A: remove B -> $STATUS $(cat "$TMP/resp.json")"
api GET "$TMP/b.auth" "/trips/$A_TRIP/photos"
[ "$STATUS" = 404 ] || fail "B after removal: photos -> $STATUS"
pass "B rejoins; A removes B -> 204; B gets 404"
accept "$TMP/b.auth" "$CODE"
[ "$STATUS" = 404 ] || fail "B rejoining with the pre-removal code -> $STATUS"
api POST "$TMP/a.auth" "/trips/$A_TRIP/invite"
CODE="$(jq -r .code "$TMP/resp.json")"; INVITES+=("$CODE")
[ "$STATUS" = 200 ] && [ "$CODE" != "${INVITES[0]}" ] || fail "removal didn't rotate the invite ($STATUS)"
pass "removal rotated the invite: B's old code -> 404, A gets a new code"
member_del "$TMP/a.auth" "$SUB_A"
[ "$STATUS" = 409 ] || fail "A: leave own trip -> $STATUS"
pass "A (owner): leave -> 409 $(jq -c . "$TMP/resp.json")"

api POST "$TMP/a.auth" "/trips/$A_TRIP/invite/rotate"
[ "$STATUS" = 201 ] || fail "A: rotate -> $STATUS $(cat "$TMP/resp.json")"
NEW_CODE="$(jq -r .code "$TMP/resp.json")"; INVITES+=("$NEW_CODE")
[ "$NEW_CODE" != "$CODE" ] || fail "rotate kept the code"
api GET "$TMP/b.auth" "/invites/$CODE"
[ "$STATUS" = 404 ] || fail "preview rotated code -> $STATUS"
accept "$TMP/b.auth" "$CODE"
[ "$STATUS" = 404 ] || fail "accept rotated code -> $STATUS"
pass "A: rotate -> 201 new code; old code preview/accept -> 404"
accept "$TMP/b.auth" "$NEW_CODE"
[ "$STATUS" = 200 ] || fail "B: accept new code -> $STATUS"
pass "B: accept new code -> 200"

echo "smoke test passed"
