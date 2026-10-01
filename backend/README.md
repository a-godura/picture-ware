# picture-ware backend

Go Lambdas behind an API Gateway HTTP API, photos in S3, metadata in
DynamoDB, users in a Cognito user pool, deployed with AWS SAM to `us-east-2`
as stack `picture-ware`. API and auth contract: [API.md](API.md).

Every route sits behind a Cognito JWT authorizer (access tokens only).
Photos are per user: DynamoDB key `(userId, id)`, S3 key
`photos/<userId>/<id>`, where `userId` is the token's `sub`.

```
cmd/api          POST/GET /photos (HTTP API, payload v2, user from JWT claims)
cmd/processor    S3 ObjectCreated on photos/<userId>/<id> -> mark item ready
cmd/killswitch   budget SNS -> throttle API to 0, zero Lambda concurrency
internal/...     handlers (depend on small interfaces) + AWS adapters
template.yaml    SAM template (Cognito pool/domain/clients, bucket, table, API, functions, kill switch)
scripts/         smoke.sh (end-to-end test), killswitch-reset.sh
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
```

Override `STACK`, `REGION`, `PROFILE` env vars for the scripts if needed.

Stack outputs the iOS app needs: `ApiUrl`, `UserPoolId`, `UserPoolClientId`,
`AuthDomain`:

```sh
aws cloudformation describe-stacks --stack-name picture-ware --region us-east-2 \
  --profile picture-ware --query 'Stacks[0].Outputs' --output table
```

The hosted UI domain prefix is the `AuthDomainPrefix` parameter (default
`picture-ware-agodura`; must be unique in the region).

Tear down: `sam delete` (empty the photo bucket first).
