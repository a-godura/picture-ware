# picture-ware backend

Go Lambdas behind an API Gateway HTTP API, photos in S3, metadata in
DynamoDB, users in a Cognito user pool, deployed with AWS SAM to `us-east-2`
as stack `picture-ware`. API and auth contract: [API.md](API.md).

Every route sits behind a Cognito JWT authorizer (access tokens only).
Everything lives in a **trip**; only its members can see it. One DynamoDB
table with generic `PK`/`SK` keys holds trips, members and photos (item
shapes in [internal/photos/store.go](internal/photos/store.go)). Photo
objects are at `trips/<tripId>/<id>`. The pre-trips `/photos` API (photos
per user, `photos/<userId>/<id>`, its own table) still runs from
[internal/legacy](internal/legacy) until no client uses it.

```
cmd/api          /trips and /trips/{tripId}/photos (HTTP API, payload v2, user from JWT claims)
cmd/processor    S3 ObjectCreated on photos/<tripId>/<id> -> mark item ready
cmd/killswitch   budget SNS -> throttle API to 0, zero Lambda concurrency
cmd/tripwire     S3 download alarm SNS -> deny s3:GetObject on photos/* and trips/*
internal/...     handlers (depend on small interfaces) + AWS adapters
template.yaml    SAM template (Cognito pool/domain/clients, bucket, table, API, functions, kill switch)
scripts/         smoke.sh (end-to-end test), killswitch-reset.sh, tripwire-reset.sh
```

## Prerequisites

Go 1.26+ (see `go.mod`), AWS SAM CLI, AWS CLI v2, `jq`, and an AWS profile named
`picture-ware` (`aws sso login --profile picture-ware`). The deploy role may
only manage IAM roles named `picture-ware-*`; SAM's generated role names are
`<stack>-<LogicalId>Role-…`, so keep the stack name `picture-ware`.

## Commands

```sh
make test               # go vet + go test (no AWS needed)
make build              # sam validate --lint && sam build
make deploy             # build + sam deploy (settings in samconfig.toml)
make smoke              # end-to-end test against the deployed stack (creates and deletes
                        # two temporary Cognito users); cleans up after itself
make killswitch-reset   # undo a triggered budget kill switch
make tripwire-reset     # unblock downloads after the download tripwire fired
```

Override `STACK`, `REGION`, `PROFILE` env vars for the scripts if needed.

## Cost guards

- **Budget kill switch** (`KillSwitchUSD`, default $5/month): throttles the
  API to 0 and zeroes Lambda concurrency. Driven by billing data, so it lags
  8-24 h. Reset: `make killswitch-reset`.
- **Download tripwire** (`DownloadTripwireBytes`, default 5 GiB per rolling
  hour): presigned GET URLs are served by S3 without the API throttle, so the
  bucket has S3 request metrics enabled and the `<stack>-download-tripwire`
  alarm on `BytesDownloaded` (re-evaluated every minute, typically a few
  minutes behind) makes `TripwireFunction` add a `TripwireDenyDownloads` Deny
  on `s3:GetObject` for `photos/*` and `trips/*` to the bucket policy. Uploads,
  listing and the API keep working; every photo download returns 403.
  - *How you find out:* the alarm is in `ALARM` state (CloudWatch console),
    the function logs `downloads blocked`, and, if the `TripwireAlertEmail`
    parameter is set, an email (confirm the SNS subscription first).
  - *Reset:* `make tripwire-reset` removes the statement (keeping the
    HTTPS-only statement) and sets the alarm back to `OK`.
  - *Caveat:* the bucket policy is also managed by CloudFormation. A deploy
    that changes `PhotosBucketPolicy` rewrites the policy and so silently
    removes an active block; check the alarm state before merging such a change.

Stack outputs the iOS app needs: `ApiUrl`, `UserPoolId`, `UserPoolClientId`,
`AuthDomain`:

```sh
aws cloudformation describe-stacks --stack-name picture-ware --region us-east-2 \
  --profile picture-ware --query 'Stacks[0].Outputs' --output table
```

The hosted UI domain prefix is the `AuthDomainPrefix` parameter (default
`picture-ware-agodura`; must be unique in the region).

Tear down: `sam delete` (empty the photo bucket first).
