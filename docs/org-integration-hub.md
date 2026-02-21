# Org Integration Hub

This repository (`LabVIEW-Community-CI-CD/labview-for-containers`) is the
governed integration hub.

Upstream product source remains:

- `ni/labview-for-containers` (`upstream` remote)

Sandbox/incubation work remains:

- `svelderrainruiz/labview-for-containers`

## Branch Model

- `main`: protected, upstream-synced integration branch.
- `stabilization/2026-*`: active delivery and certification work.
- `stabilization/2020-*`: isolated diagnostics and hardening work.
- `sync/upstream-*`: upstream sync proposals when fast-forward is not possible.

## Governance Policy

- Direct pushes to `main` are blocked by branch protection.
- Pull requests must be up-to-date with `main`.
- Required checks enforce regression and certification gates.
- Issue tracking and acceptance decisions happen in this org repository.

## Upstream Sync Policy

- Scheduled daily sync plus manual dispatch via
  `.github/workflows/upstream-main-sync.yml`.
- Sync outcomes:
  - `in_sync`
  - `fast_forwarded`
  - `conflict_requires_pr`
- On conflict, automation opens `sync/upstream-<timestamp>` PR with context.

## Delivery Policy

- Stabilize 2026 first using hosted certification evidence.
- Keep canonical 2020 promotion frozen until promotion gate criteria are met in
  a qualified environment lane.
- Align 2026 execution with NI `v2026q1` release notes:
  - Windows container support is official.
  - Headless mode is the expected automation mode (`LabVIEWCLI ... -Headless`).
