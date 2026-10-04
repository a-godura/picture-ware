# API contract

[`openapi.yaml`](openapi.yaml) is the contract between the iOS app and the
backend. Each side is tested against it on its own, so neither needs the
other running:

- **Backend**: every response produced in the handler tests
  (`backend/internal/api` for `/trips`, `backend/internal/legacy/api` for
  `/photos`) is validated against the contract via
  `backend/internal/contracttest`, and the routes in `backend/template.yaml`
  must be exactly the documented ones, except operations marked
  `x-planned: true` (`go test ./internal/...` from `backend/`).
- **CI** (`contract / breaking-changes`): a PR fails if it changes the contract
  in a way that breaks clients built against `main` (removed routes or fields,
  new required inputs, ...). Additive changes pass. Operations marked
  `x-planned: true` on `main` are left out of that comparison
  (`backend/tools/dropplanned`): nothing deployed or shipped uses them, so
  reshaping them isn't breaking. A deliberate breaking change to anything
  deployed needs the `breaking-change-approved` label.

## Changing the API

1. Change `openapi.yaml` first (additively), with examples. Mark new
   operations `x-planned: true`: they're agreed but not deployed yet, so the
   route check doesn't expect them in `template.yaml`, and the app can build
   against them in mock mode. Planned operations can still be changed or
   removed without the breaking-change label. Then run
   `ios/scripts/sync-contract.sh` and commit the regenerated `openapi.json`,
   which the app and its tests read (the `ios` workflow fails if it's out of
   date).
2. Implement it in the backend; its tests must match the contract. The same
   PR removes `x-planned` from the operations it deploys.
3. Build the app against the contract. Backend and app can ship in separate
   PRs, in either order.
4. Remove something only once no client uses it, in its own PR with the
   `breaking-change-approved` label.

Check locally, from the repo root, exactly as CI does:

```sh
git show origin/main:api/openapi.yaml | (cd backend && go run ./tools/dropplanned) > /tmp/base.yaml
oasdiff breaking /tmp/base.yaml api/openapi.yaml
```

(install: `go install github.com/oasdiff/oasdiff@latest`).
