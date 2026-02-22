# Upstream Sync Runbook

This runbook defines how `LabVIEW-Community-CI-CD/labview-for-containers`
ingests changes from `ni/labview-for-containers` while keeping `main`
protected and PR-only.

## Source-of-Truth Policy

- Active stabilization decisions are made in this org repository.
- Personal sandbox forks are read-only mirrors for reference.
- Upstream ingestion is automated through `.github/workflows/upstream-sync.yml`.

## Branch Model

- `main`: protected integration branch.
- `sync/upstream-*`: automation branches created by the sync workflow.
- `stabilization/*`: active stabilization work branches.

## Workflow Interface

Workflow: `.github/workflows/upstream-sync.yml`

Triggers:

- `schedule` (daily UTC)
- `workflow_dispatch`

Dispatch inputs:

- `upstream_ref` (default `main`)
- `sync_mode` (`detect-only` or `propose-pr`, default `propose-pr`)
- `pr_base` (default `main`)
- `sync_branch_prefix` (default `sync/upstream`)
- `dry_run` (default `false`)

Permissions:

- `contents: write`
- `pull-requests: write`
- `issues: write`

## Classification Contract

Each run emits one classification and writes:

- `builds/status/upstream-sync-summary-<timestamp>.json`

Classifications:

- `in_sync`
- `behind_requires_sync_pr`
- `sync_pr_opened`
- `sync_pr_updated`
- `conflict_requires_pr`
- `execution_error`

## Behavior Rules

1. Never push directly to `main`.
1. When org `main` is behind upstream and PR mode is enabled, open/update one
   sync PR for the configured upstream ref.
1. When histories are divergent, classify `conflict_requires_pr` and open/update
   a sync PR for manual resolution.
1. In `detect-only` mode, do not push branches or open PRs.
1. Keep PR creation idempotent (reuse/update existing open sync PR when present).

## Tracking and Notifications

- `conflict_requires_pr` and `execution_error` runs must post evidence to the
  active upstream-sync tracking issue.
- Include run URL, summary JSON path, base/upstream SHAs, and sync branch.

## Manual Operations

Dispatch detect-only:

```powershell
gh workflow run upstream-sync.yml `
  --repo LabVIEW-Community-CI-CD/labview-for-containers `
  -f upstream_ref=main `
  -f sync_mode=detect-only `
  -f pr_base=main `
  -f sync_branch_prefix=sync/upstream `
  -f dry_run=true
```

Dispatch PR mode:

```powershell
gh workflow run upstream-sync.yml `
  --repo LabVIEW-Community-CI-CD/labview-for-containers `
  -f upstream_ref=main `
  -f sync_mode=propose-pr `
  -f pr_base=main `
  -f sync_branch_prefix=sync/upstream `
  -f dry_run=false
```
