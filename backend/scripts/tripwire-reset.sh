#!/usr/bin/env bash
# Undo the download tripwire: remove the TripwireDenyDownloads statement from
# the photo bucket policy (keeping every other statement) and set the alarm
# back to OK so a new breach trips it again. Investigate the spike first
# (CloudWatch: AWS/S3 BytesDownloaded, FilterId=EntireBucket).
set -euo pipefail

STACK="${STACK:-picture-ware}"
REGION="${REGION:-us-east-2}"
PROFILE="${PROFILE:-picture-ware}"
SID="TripwireDenyDownloads"
AWS=(aws --region "$REGION" --profile "$PROFILE")

output() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

BUCKET="$(output BucketName)"
ALARM="$(output DownloadTripwireAlarmName)"

policy="$("${AWS[@]}" s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text)"
if ! jq -e --arg sid "$SID" '[.Statement] | flatten | any(.Sid == $sid)' <<<"$policy" >/dev/null; then
  echo "No $SID statement on $BUCKET; downloads are not blocked."
else
  new="$(jq -c --arg sid "$SID" '.Statement = ([.Statement] | flatten | map(select(.Sid != $sid)))' <<<"$policy")"
  if [ "$(jq '.Statement | length' <<<"$new")" -eq 0 ]; then
    echo "Refusing to write an empty policy (the stack's HTTPS-only statement is missing); fix the stack first." >&2
    exit 1
  fi
  echo "Removing $SID from the bucket policy of $BUCKET"
  "${AWS[@]}" s3api put-bucket-policy --bucket "$BUCKET" --policy "$new"
fi

echo "Setting alarm $ALARM to OK (it re-evaluates every minute and trips again if downloads in the last hour are still above the threshold)"
"${AWS[@]}" cloudwatch set-alarm-state --alarm-name "$ALARM" --state-value OK \
  --state-reason "Manual reset via tripwire-reset.sh"

echo "Tripwire reset. If the traffic was legitimate, raise DownloadTripwireBytes (via a template PR) instead of resetting repeatedly."
