# Image Contract Incident Response

Use this runbook when certification regresses or becomes non-deterministic.

## 1. Freeze and Classify

1. Freeze promotion actions for the affected track.
1. Capture the failing classification from cert summary:
   `builds/status/image-contract-cert-summary-*.json`.
1. Post the run URL, summary path, and classification in the tracking issue.

## 2. Preserve Evidence

Collect and attach:

- certification summary JSON
- verifier `summary.json`
- `netstat` snapshot
- process list
- `LabVIEW.ini` and `LabVIEWCLI.ini` snapshots
- `lvtemporary_*` and LabVIEW user logs

## 3. Apply Classification Playbook

- `verifier_execution_error`
  - Fix preflight/image acquisition/script execution first.
- `environment_incompatible`
  - Fix runner lane and environment contract first.
- `port_not_listening`
  - Tune readiness/launch timing and listener checks.
- `cli_connect_fail`
  - Tune CLI connectivity and retry behavior.

## 4. Re-run Deterministically

1. Re-run with identical inputs on the same branch/SHA after fix.
1. Require two consecutive pass runs for throughput/certification acceptance.
1. Keep failed and passed evidence linked in one issue timeline.

## 5. Escalation

Escalate when any of these occur:

- same failure classification repeats after two fix attempts
- conflicting outcomes across identical inputs
- required environment lane unavailable for promotion gate verification

