# LabVIEW Container Parity

This runbook defines host-side parity checks for dedicated self-hosted Windows
validation machines.

## Scope

- Host contract enforcement for LabVIEW installs and CLI resolution.
- Port contract validation for host-native automation.
- Runner sanity gating before parity/certification workflows.

## Runtime Requirement

- `Tooling/Check-Runner.ps1` requires PowerShell 7.0 or later (`pwsh`).

## Enforcement Inputs

- Host contract: `Tooling/runner-host-contract.json`
- Host port contract: `Tooling/labviewcli-port-contract.json`
- Validation script: `Tooling/Check-Runner.ps1`

## Command

```powershell
powershell -NoProfile -NonInteractive -File .\Tooling\Check-Runner.ps1 `
  -RepoRoot (Get-Location).Path `
  -EnforceHostContract `
  -HostContractPath .\Tooling\runner-host-contract.json
```

## Policy Note

This host parity contract is separate from the container image-contract
profiles used by certification workflows.
