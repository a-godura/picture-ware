# How changes are made

These rules apply to everyone working on this repo, human or agent.

## Shipping

1. **Contract first.** Any API change starts in [`api/openapi.yaml`](api/openapi.yaml),
   additively, with examples. See [`api/README.md`](api/README.md). New
   operations land marked `x-planned: true` (agreed, not deployed yet); the
   backend PR that deploys them removes the marker.
2. **Backend and app ship separately.** A PR touches `backend/` *or* `ios/`
   (plus `api/` when needed), never both. Each side must be fully testable
   without the other: backend tests use fakes and the contract tests; app tests
   use stubbed networking and the contract's examples (mock mode).
3. **Additive, then migrate, then remove.** Never remove or rename something a
   shipped client uses in the same change that adds its replacement. Removal is
   its own PR with the `breaking-change-approved` label.
4. **Small PRs**, one concern each, linked to an issue (`Part of #n` /
   `Closes #n`). Branch names: `<type>/<issue>-<slug>` (e.g. `feat/12-add-members`).
5. **Never push to `main`; never merge your own PR.** PRs merge only when CI is
   green and the DevOps review (and, for anything touching AWS resources, the
   cost review) passes.
6. **CI deploys; nobody deploys from a laptop.** Merging a `backend/` change to
   `main` deploys it. Local AWS use is read-only, plus CloudFormation change-set
   *previews* (create, inspect, delete; never execute).
7. **Data migrations** are separate PRs: idempotent scripts, a backup first,
   copy rather than move until the old path is retired.

## Required checks before asking for review

- Backend: `cd backend && make test && sam validate --lint && sam build`
- App: `cd ios && xcodegen generate` (if files were added) then
  `xcodebuild test -project PictureWare.xcodeproj -scheme PictureWare -destination 'platform=iOS Simulator,id=<your own simulator>'`
- Contract: `oasdiff breaking <(git show origin/main:api/openapi.yaml) api/openapi.yaml`
- No secrets, tokens, passwords or AWS account IDs in the repo (it's public).

## Commits and PRs

- Commit messages explain *why*; end with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` when an agent wrote them.
- PR description: what changed, how it was verified (real command output),
  what's deliberately left out, and for AWS changes a **cost note** (new
  resources, expected monthly cost at current scale and at 100× usage,
  guardrails). End agent-written PRs with
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## Cost rules

- Prefer pay-per-request, scale-to-zero services. No always-on resources (NAT
  gateways, provisioned databases, load balancers, provisioned concurrency)
  without explicit approval.
- Every public entry point stays throttled; uploads stay size-capped; logs
  keep a retention period.
- The `picture-ware-killswitch` budget and the `zero-spend` alert must keep
  working.

## Parallel work (agents)

- Work in your own git worktree and branch; rebase on `origin/main` before
  asking for review.
- Use your own simulator (`xcrun simctl clone` / `create`, named after your
  branch) and your own `-derivedDataPath`; delete the simulator when done.
  Don't use the shared "iPhone 18 Pro" simulator.
- Product decisions aren't yours to make silently: if one is needed, stop and
  report the question with options and a recommendation.
