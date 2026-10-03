# picture-ware API (v1)

The authoritative, machine-checked contract (with examples) is
[`api/openapi.yaml`](../api/openapi.yaml); this page is a readable overview.

Base URL: the `ApiUrl` output of the `picture-ware` CloudFormation stack
(`https://<api-id>.execute-api.us-east-2.amazonaws.com`).

All responses are JSON (`Content-Type: application/json`). Errors are
`{"error": "<message>"}` with a 4xx/5xx status.

## Authentication

Every route requires a **Cognito access token**:

```
Authorization: Bearer <access_token>
```

Everything lives inside a **trip** (a vacation or an event). A trip and its
photos are visible only to its **members**; to anyone else the trip doesn't
exist (`404`). The creator is the first member. The user id is the token's
`sub` claim.

### Cognito setup (stack outputs)

| output             | example                                                        |
|--------------------|----------------------------------------------------------------|
| `UserPoolId`       | `us-east-2_XXXXXXXXX`                                          |
| `UserPoolClientId` | public app client id (no secret)                               |
| `AuthDomain`       | `https://picture-ware-agodura.auth.us-east-2.amazoncognito.com` |
| `ApiUrl`           | API base URL                                                   |

- Sign-in identifier is the user's **email** (username = email). Self sign-up
  is on; new users confirm their email with a code Cognito emails them.
  Passwords: at least 8 characters, no other complexity rules.
- Hosted UI (classic managed login) at `AuthDomain`.
- App client: **authorization code grant with PKCE** only, no client secret,
  scopes `openid email profile`, identity provider `COGNITO`.
  - Callback URL: `picture-ware://auth/callback`
  - Sign-out URL: `picture-ware://auth/signout`
- Token lifetimes: access and ID tokens **1 hour**, refresh token **30 days**.
  Refresh-token revocation is enabled (`/oauth2/revoke`); user-existence
  errors are suppressed.

### Getting a token (iOS)

1. Generate a PKCE `code_verifier` and its S256 `code_challenge`.
2. Open (e.g. `ASWebAuthenticationSession`, callback scheme `picture-ware`):
   ```
   {AuthDomain}/oauth2/authorize?response_type=code&client_id={UserPoolClientId}
     &redirect_uri=picture-ware://auth/callback&scope=openid+email+profile
     &code_challenge={challenge}&code_challenge_method=S256&state={state}
   ```
   The hosted UI handles sign-in, sign-up and email verification.
3. On `picture-ware://auth/callback?code=…&state=…`, exchange the code:
   ```
   POST {AuthDomain}/oauth2/token
   Content-Type: application/x-www-form-urlencoded

   grant_type=authorization_code&client_id={UserPoolClientId}
   &code={code}&redirect_uri=picture-ware://auth/callback&code_verifier={verifier}
   ```
   → `{access_token, id_token, refresh_token, expires_in, token_type}`.
4. Send `access_token` as the bearer token. **Do not send the ID token** — it
   is rejected with 401.
5. Refresh before/after expiry:
   `grant_type=refresh_token&client_id={UserPoolClientId}&refresh_token={rt}`
   to the same token endpoint.
6. Sign out: `POST {AuthDomain}/oauth2/revoke` with
   `token={refresh_token}&client_id={UserPoolClientId}`, then open
   `{AuthDomain}/logout?client_id={UserPoolClientId}&logout_uri=picture-ware://auth/signout`
   to clear the hosted-UI session cookie.

OIDC discovery:
`https://cognito-idp.us-east-2.amazonaws.com/{UserPoolId}/.well-known/openid-configuration`.

### Auth errors

| status | body                          | when                                                        |
|--------|-------------------------------|-------------------------------------------------------------|
| 401    | `{"message":"Unauthorized"}`  | missing, malformed, expired or wrong-issuer/audience token (API Gateway) |
| 401    | `{"error":"unauthorized"}`    | valid JWT that is not an access token (e.g. an ID token)    |

On 401, refresh the access token once and retry; if refresh fails, sign in again.

The stack also has a test-only `SmokeTestClient` (admin password auth, no
OAuth) used by `scripts/smoke.sh` through IAM-authenticated admin APIs; apps
must not use it.

## Flow

1. The app signs the user in (above).
2. `POST /trips` creates a trip; `GET /trips` lists the caller's trips.
3. The app reads the GPS location (and capture time) from the photo's own
   metadata on device. HEIC is common, so the server does no EXIF parsing.
4. `POST /trips/{tripId}/photos` with the location → get an `id` and a
   presigned S3 POST.
5. Upload the image bytes directly to S3 with that presigned POST.
6. S3 `ObjectCreated` triggers the processor Lambda, which marks the photo `ready`.
7. `GET /trips/{tripId}/photos` returns the trip's ready photos, in capture
   order, with a short-lived `imageUrl` to show on the map.

## Trips

```json
{
  "id": "7d7d7d7d-3333-4c4c-9d9d-0123456789ab",
  "name": "Lisbon",
  "startDate": "2026-10-01",
  "endDate": "2026-10-07",
  "createdBy": "<sub>",
  "createdAt": "2026-10-03T18:00:00Z"
}
```

`startDate` / `endDate` are calendar days (`YYYY-MM-DD`); `endDate` is `null`
when not set.

### `POST /trips`

Body (unknown fields rejected): `{"name": "Lisbon", "startDate": "2026-10-01", "endDate": "2026-10-07"}`

- `name`: required, trimmed, 1–100 characters
- `startDate`: required date; `endDate`: optional date, not before `startDate`

`201` with the trip. The caller becomes its creator and first member.
Errors: `400` validation, `401`, `413` body > 4 KiB, `429`, `500`.

### `GET /trips`

`200 {"trips": [<trip>, …]}`: trips the caller is a member of, newest
`startDate` first. Always an array.

### `GET /trips/{tripId}`

`200` with the trip; `404 {"error":"trip not found"}` if it doesn't exist or
the caller isn't a member.

## `POST /trips/{tripId}/photos`

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
      "key": "trips/<tripId>/6f1c0e8e-5d0b-4b8a-9f1e-2a3b4c5d6e7f",
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
`GET /trips/{tripId}/photos` until the upload lands. Only trip members can
add photos (`404` otherwise).

### Uploading to S3

Send `multipart/form-data` to `upload.url` with **every** entry of
`upload.fields` as a form field (copy them verbatim, do not hard-code the
names), followed **last** by the image in a field named `file`:

```sh
curl -F key=… -F Content-Type=image/jpeg -F policy=… … -F file=@photo.jpg "$URL"
```

The presigned policy enforces:

- exact key `trips/<tripId>/<id>`
- exact `Content-Type` (the one sent when creating the photo)
- size 1 byte … 15 MiB (15,728,640 bytes)
- expires 10 minutes after creation

S3 answers `204 No Content` on success; `403 AccessDenied` on a policy
violation (wrong key / content type / expired); `400 EntityTooLarge` for
oversized files (S3 may also just reset the connection).

### Errors

| status | when                                             |
|--------|--------------------------------------------------|
| 400    | malformed JSON, unknown field, validation failure |
| 401    | missing/invalid token (see Authentication)       |
| 404    | trip not found, or caller isn't a member         |
| 413    | body > 4 KiB                                     |
| 429    | throttled (`{"message":"Too Many Requests"}`, see below), or an upload quota reached (`{"error": ...}`, see Upload quotas) |
| 500    | internal error                                   |

### Upload quotas

Checked before an upload URL is issued; over a quota nothing is created and
the response is `429` with one of:

| `error`                         | meaning (defaults)                                     |
|---------------------------------|--------------------------------------------------------|
| `daily upload limit reached`    | caller got 300 upload URLs today (UTC)                 |
| `storage limit reached`         | caller stores 5 GiB (delete photos to free space)      |
| `service storage limit reached` | all users together store 50 GiB (try again later)      |

Each upload URL reserves 15 MiB of storage until the upload lands (then the
real size counts instead) or about an hour passes without it landing.
Deleting a photo frees its storage but not the daily count. The legacy
`/photos` routes are not metered.

## `GET /trips/{tripId}/photos`

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
      "uploaderId": "<sub>",
      "imageUrl": "https://<bucket>.s3.us-east-2.amazonaws.com/trips/…?X-Amz-…"
    }
  ],
  "nextCursor": null
}
```

- All of the trip's photos with status `ready`, from every member, in capture
  order (`takenAt`); photos without `takenAt` come last, by upload time.
  `photos` is always an array.
- `uploaderId` is the `sub` of the member who added it.
- `takenAt` is `null` when it was not supplied.
- `imageUrl` is a presigned GET valid for **1 hour** (it is signed with the
  Lambda's temporary credentials, so in rare cases it can expire sooner if
  those credentials rotate). Re-fetch the list rather than caching URLs.
- Paginated: `?limit=` (1-500, default 200). While `nextCursor` is a
  string, pass it back as `?cursor=` for the next page; it is `null` on the
  last page. The order holds across pages; a page can be shorter than
  `limit` (even empty) while `nextCursor` is set.
- Errors: `400` (bad `limit` or `cursor`), `401` (see Authentication),
  `404`, `429`, `500`.

## `DELETE /trips/{tripId}/photos/{photoId}`

Deletes a photo from a trip. Only the member who **uploaded** it can delete
it (for now). The S3 object goes first, then the record, so a failure
part-way leaves the photo listed and the client can simply retry.

- `204 No Content` (empty body) on success.
- `403` if the caller is a member but didn't upload the photo.
- `404` if the trip or photo doesn't exist, or the caller isn't a member.
- Deleting a `pending` photo (upload never finished) also works.
- Errors: `401` (see Authentication), `403`, `404`, `429`, `500`.

## Legacy `/photos` routes (deprecated)

`POST /photos`, `GET /photos` and `DELETE /photos/{id}` still work exactly as
before trips existed (photos owned by the caller, objects at
`photos/<userId>/<id>`, separate table) so already-installed app builds keep
working. New clients use `/trips`. They'll be removed once no client calls them.

## Limits and cost guardrails

- **Throttling:** HTTP API default route throttling of **5 req/s, burst 10**
  (template parameters `ThrottleRateLimit` / `ThrottleBurstLimit`). Excess
  requests get `429`.
- **Reserved concurrency: not set.** `aws lambda get-account-settings` reports
  an account `ConcurrentExecutions` limit of **10**. Lambda requires at least 10
  unreserved concurrency to remain, so no function can reserve any (the
  account-wide limit of 10 is itself the cap). Revisit once the quota is raised.
- **Upload size:** 15 MiB max per object (presigned policy).
- **Upload quotas (trips only):** per user 300 upload URLs/day
  (`UploadsPerUserPerDay`) and 5 GiB stored (`StoragePerUserBytes`); 50 GiB
  stored in total (`StorageTotalBytes`). Counters live in AppTable
  (`USAGE#...` items, see `internal/photos/quota.go`). Concurrent requests
  cannot overshoot: every upload URL reserves the 15 MiB maximum in the same
  transaction that checks the caps. The only overshoot is an upload that
  lands after its reservation was released as stale (more than an hour
  after the 10-minute URL was issued), at most 15 MiB each.
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
