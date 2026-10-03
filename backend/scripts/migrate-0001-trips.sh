#!/usr/bin/env bash
# One-off migration (October 2026): photos used to belong to a user
# (old table keyed userId/id, objects at photos/<userId>/<id>). Now they
# belong to a trip. For every user in BACKUP (a `dynamodb scan --output json`
# of the old table), this creates a trip called "My first trip" with that user
# as creator and member, moves their photos into it, and moves each object to
# photos/<tripId>/<id>. Safe to re-run: it skips users who already have trips.
#
# Usage: scripts/migrate-0001-trips.sh BACKUP.json
set -euo pipefail

BACKUP="${1:?usage: $0 BACKUP.json}"
STACK="${STACK:-picture-ware}"
REGION="${REGION:-us-east-2}"
PROFILE="${PROFILE:-picture-ware}"
AWS=(aws --region "$REGION" --profile "$PROFILE")

output() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
TABLE="$(output TableName)"; BUCKET="$(output BucketName)"
echo "table=$TABLE bucket=$BUCKET"

put() { "${AWS[@]}" dynamodb put-item --table-name "$TABLE" --item "$1" >/dev/null; }

for user in $(jq -r '[.Items[].userId.S] | unique | .[]' "$BACKUP"); do
  existing="$("${AWS[@]}" dynamodb query --table-name "$TABLE" \
    --key-condition-expression "PK = :pk" \
    --expression-attribute-values "{\":pk\":{\"S\":\"USER#$user\"}}" --select COUNT --query Count)"
  if [ "$existing" != 0 ]; then
    echo "skip $user: already has $existing trip(s)"
    continue
  fi

  trip="$(uuidgen | tr 'A-Z' 'a-z')"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Trip starts on the day of the user's earliest photo (or today).
  start="$(jq -r --arg u "$user" '[.Items[] | select(.userId.S == $u) | (.takenAt.S // .createdAt.S)] | min | .[0:10]' "$BACKUP")"
  [ "$start" = "null" ] && start="${now:0:10}"
  trip_attrs="$(jq -n --arg t "$trip" --arg u "$user" --arg s "$start" --arg n "$now" \
    '{tripId:{S:$t}, name:{S:"My first trip"}, startDate:{S:$s}, createdBy:{S:$u}, createdAt:{S:$n}}')"

  put "$(jq -n --argjson a "$trip_attrs" --arg t "$trip" '$a + {PK:{S:("TRIP#"+$t)}, SK:{S:"META"}, type:{S:"trip"}}')"
  put "$(jq -n --arg t "$trip" --arg u "$user" '{PK:{S:("TRIP#"+$t)}, SK:{S:("MEMBER#"+$u)}, type:{S:"member"}, userId:{S:$u}}')"
  put "$(jq -n --argjson a "$trip_attrs" --arg t "$trip" --arg u "$user" '$a + {PK:{S:("USER#"+$u)}, SK:{S:("TRIP#"+$t)}, type:{S:"userTrip"}}')"
  echo "created trip $trip for $user (start $start)"

  jq -c --arg u "$user" '.Items[] | select(.userId.S == $u)' "$BACKUP" | while read -r old; do
    id="$(jq -r .id.S <<<"$old")"
    # Same attributes, re-keyed under the trip; userId becomes uploaderId.
    put "$(jq -c --arg t "$trip" --arg u "$user" --arg id "$id" \
      'del(.userId) + {PK:{S:("TRIP#"+$t)}, SK:{S:("PHOTO#"+$id)}, type:{S:"photo"}, tripId:{S:$t}, uploaderId:{S:$u}}' <<<"$old")"
    if "${AWS[@]}" s3api head-object --bucket "$BUCKET" --key "photos/$user/$id" >/dev/null 2>&1; then
      "${AWS[@]}" s3 mv "s3://$BUCKET/photos/$user/$id" "s3://$BUCKET/photos/$trip/$id" >/dev/null
      echo "  moved photo $id"
    else
      echo "  photo $id: no object at photos/$user/$id (record kept as-is)"
    fi
  done
done
echo "done"
