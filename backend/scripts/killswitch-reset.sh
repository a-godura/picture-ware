#!/usr/bin/env bash
# Undo the budget kill switch: restore HTTP API throttling to the stack's
# parameter values and remove the zero reserved-concurrency overrides.
set -euo pipefail

STACK="${STACK:-picture-ware}"
REGION="${REGION:-us-east-2}"
PROFILE="${PROFILE:-picture-ware}"
AWS=(aws --region "$REGION" --profile "$PROFILE")

stack() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].$1" --output text
}
output() { stack "Outputs[?OutputKey=='$1'].OutputValue"; }
param() { stack "Parameters[?ParameterKey=='$1'].ParameterValue"; }

API_ID="$(output ApiId)"
RATE="$(param ThrottleRateLimit)"
BURST="$(param ThrottleBurstLimit)"

echo "Restoring \$default stage throttling on $API_ID to rate=$RATE burst=$BURST"
"${AWS[@]}" apigatewayv2 update-stage --api-id "$API_ID" --stage-name '$default' \
  --default-route-settings "ThrottlingRateLimit=$RATE,ThrottlingBurstLimit=$BURST" \
  --query DefaultRouteSettings --output json

for key in ApiFunctionName ProcessorFunctionName; do
  fn="$(output "$key")"
  echo "Removing reserved concurrency override on $fn"
  "${AWS[@]}" lambda delete-function-concurrency --function-name "$fn"
done

echo "Kill switch reset. Note: the budget will fire again while month-to-date cost stays above the limit;"
echo "raise KillSwitchUSD (sam deploy --parameter-overrides KillSwitchUSD=N) if this is intentional spend."
