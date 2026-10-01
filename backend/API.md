# picture-ware API (v1)

Base URL: the `ApiUrl` output of the `picture-ware` CloudFormation stack
(`https://<api-id>.execute-api.us-east-2.amazonaws.com`).

All responses are JSON (`Content-Type: application/json`). Errors are
`{"error": "<message>"}` with a 4xx/5xx status.

> **TODO (auth):** v1 has **no authentication**. Anyone with the URL can create
> upload slots and list every photo. Add auth (e.g. Cognito / Sign in with Apple
> JWT authorizer on the HTTP API) before real use.

## Flow

1. iOS reads the GPS location (and capture time) from the photo's own metadata
   on device. HEIC is common, so the server does no EXIF parsing in v1.
2. `POST /photos` with the location → get an `id` and a presigned S3 POST.
3. Upload the image bytes directly to S3 with that presigned POST.
4. S3 `ObjectCreated` triggers the processor Lambda, which marks the photo `ready`.
5. `GET /photos` returns ready photos with a short-lived `imageUrl` to show on the map.

## `POST /photos`

Request body (unknown fields are rejected):

```json
{
  "lat": 37.7749,
  "lng": -122.4194,
  "takenAt": "2026-09-01T10:00:00Z",
  "contentType": "image/jpeg"
}
```

| field         | type   | required | rules                                       |
|---------------|--------|----------|---------------------------------------------|
| `lat`         | number | yes      | -90 … 90                                    |
| `lng`         | number | yes      | -180 … 180                                  |
| `takenAt`     | string | no       | RFC 3339 timestamp                          |
| `contentType` | string | yes      | `image/jpeg` or `image/heic`                |

Body limit 4 KiB.

### 201 Created

```json
{
  "id": "6f1c0e8e-5d0b-4b8a-9f1e-2a3b4c5d6e7f",
  "upload": {
    "url": "https://<bucket>.s3.us-east-2.amazonaws.com",
    "fields": {
      "key": "photos/6f1c0e8e-5d0b-4b8a-9f1e-2a3b4c5d6e7f",
      "Content-Type": "image/jpeg",
      "policy": "…",
      "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
      "X-Amz-Credential": "…",
      "X-Amz-Date": "…",
      "X-Amz-Security-Token": "…",
      "X-Amz-Signature": "…"
    }
  }
}
```

The record is stored with status `pending` and is **not** returned by
`GET /photos` until the upload lands.

### Uploading to S3

Send `multipart/form-data` to `upload.url` with **every** entry of
`upload.fields` as a form field (copy them verbatim, do not hard-code the
names), followed **last** by the image in a field named `file`:

```sh
curl -F key=… -F Content-Type=image/jpeg -F policy=… … -F file=@photo.jpg "$URL"
```

The presigned policy enforces:

- exact key `photos/<id>`
- exact `Content-Type` (the one sent to `POST /photos`)
- size 1 byte … 15 MiB (15,728,640 bytes)
- expires 10 minutes after creation

S3 answers `204 No Content` on success; `403 AccessDenied` on a policy
violation (wrong key / content type / expired); `400 EntityTooLarge` for
oversized files (S3 may also just reset the connection).

### Errors

| status | when                                             |
|--------|--------------------------------------------------|
| 400    | malformed JSON, unknown field, validation failure |
| 413    | body > 4 KiB                                     |
| 429    | throttled (see below)                            |
| 500    | internal error                                   |

## `GET /photos`

### 200 OK

```json
{
  "photos": [
    {
      "id": "6f1c0e8e-5d0b-4b8a-9f1e-2a3b4c5d6e7f",
      "lat": 37.7749,
      "lng": -122.4194,
      "takenAt": "2026-09-01T10:00:00Z",
      "createdAt": "2026-10-01T18:00:00Z",
      "imageUrl": "https://<bucket>.s3.us-east-2.amazonaws.com/photos/…?X-Amz-…"
    }
  ]
}
```

- Only photos with status `ready` are returned. `photos` is always an array.
- `takenAt` is `null` when it was not supplied.
- `imageUrl` is a presigned GET valid for **1 hour** (it is signed with the
  Lambda's temporary credentials, so in rare cases it can expire sooner if
  those credentials rotate). Re-fetch the list rather than caching URLs.
- No pagination in v1 (the table is scanned).

## Limits and cost guardrails

- **Throttling:** HTTP API default route throttling of **5 req/s, burst 10**
  (template parameters `ThrottleRateLimit` / `ThrottleBurstLimit`). Excess
  requests get `429`.
- **Reserved concurrency: not set.** `aws lambda get-account-settings` reports
  an account `ConcurrentExecutions` limit of **10**. Lambda requires at least 10
  unreserved concurrency to remain, so no function can reserve any (the
  account-wide limit of 10 is itself the cap). Revisit once the quota is raised.
- **Upload size:** 15 MiB max per object (presigned policy).
- **Logs:** every function's log group keeps 14 days.
- **S3:** incomplete multipart uploads are aborted after 1 day.
- **Kill switch:** an AWS Budget `picture-ware-killswitch` (monthly actual
  cost of the whole account, limit = parameter `KillSwitchUSD`, default $5)
  publishes to an SNS topic when actual spend exceeds 100%. A Lambda subscribed
  to the topic sets the `$default` stage throttling to **0/0** (every request
  gets `429`) and puts reserved concurrency **0** on the API and processor
  functions. Undo with `backend/scripts/killswitch-reset.sh` (or `make
  killswitch-reset`). Budgets evaluate a few times a day, so this caps runaway
  spend rather than stopping it instantly.
