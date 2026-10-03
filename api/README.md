# API contract

[`openapi.yaml`](openapi.yaml) is the contract between the iOS app and the
backend. Each side is tested against it on its own, so neither needs the
other running:

- **Backend**: every response produced in the handler tests
  (`backend/internal/api` for `/trips`, `backend/internal/legacy/api` for
  `/photos`) is validated against the contract via
  `backend/internal/contracttest`, and the routes in `backend/template.yaml`
  must be exactly the documented ones (`go test ./internal/...` from
  `backend/`).
- **CI** (`contract / breaking-changes`): a PR fails if it changes the contract
  in a way that breaks clients built against `main` (removed routes or fields,
  new required inputs, ...). Additive changes pass. A deliberate breaking
  change needs the `breaking-change-approved` label.

## Changing the API

1. Change `openapi.yaml` first (additively), with examples.
2. Implement it in the backend; its tests must match the contract.
3. Build the app against the contract. Backend and app can ship in separate
   PRs, in either order.
4. Remove something only once no client uses it, in its own PR with the
   `breaking-change-approved` label.

Check locally: `oasdiff breaking <(git show main:api/openapi.yaml) api/openapi.yaml`
(install: `go install github.com/oasdiff/oasdiff@latest`).
