[CmdletBinding()]
param(
    [ValidateSet('Conservative', 'Aggressive')][string]$Mode = 'Conservative',
    [switch]$Apply,
    [string[]]$KeepImageTags = @(
        'labview-custom-windows:2020q1-windows',
        'labview-custom-windows:2020q1-windows-p3363-candidate',
        'nationalinstruments/labview:2026q1-windows',
        'mcr.microsoft.com/windows/server:ltsc2022'
    ),
    [string[]]$KeepVolumes = @(
        'vm'
    ),
    [string[]]$KeepLogPrefixes = @(
        'p3363-',
        'ppl-phase3-'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-Timestamp {
    return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Confirm-DockerAvailable {
    & docker version --format '{{.Server.Os}}' > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker daemon is unavailable. Start Docker Desktop in Windows mode and retry.'
    }
}

function Get-AllImageTags {
    $rows = & docker image ls --format '{{.Repository}}:{{.Tag}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to enumerate Docker images.'
    }

    return @($rows | ForEach-Object { $_.Trim() } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            -not $_.StartsWith('<none>:')
        })
}

function Get-AllVolumes {
    $rows = & docker volume ls --format '{{.Name}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to enumerate Docker volumes.'
    }

    return @($rows | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ExitedContainers {
    $rows = & docker ps -a --filter 'status=exited' --format '{{.ID}} {{.Names}} {{.Image}} {{.Status}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to enumerate exited containers.'
    }

    return @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Remove-ImageTagIfPresent {
    param([Parameter(Mandatory = $true)][string]$Tag)

    & docker image inspect $Tag > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        return
    }

    & docker image rm $Tag
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to remove image tag '$Tag'."
    }
}

function Remove-VolumeIfPresent {
    param([Parameter(Mandatory = $true)][string]$Name)

    & docker volume inspect $Name > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        return
    }

    & docker volume rm $Name
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to remove volume '$Name'."
    }
}

function Test-StartsWithAny {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string[]]$Prefixes
    )

    foreach ($prefix in $Prefixes) {
        if ($Value.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

Confirm-DockerAvailable

$repoRoot = Get-RepoRoot
$logRoot = Join-Path $repoRoot 'TestResults\agent-logs'
New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
$timestamp = Get-Timestamp
$runRoot = Join-Path $logRoot ("cleanup-{0}-{1}" -f $Mode.ToLowerInvariant(), $timestamp)
New-Item -Path $runRoot -ItemType Directory -Force | Out-Null

$allImageTags = Get-AllImageTags
$allVolumes = Get-AllVolumes
$exitedContainers = Get-ExitedContainers
$missingKeepTags = @($KeepImageTags | Where-Object { $allImageTags -notcontains $_ })
$missingKeepTagCount = @($missingKeepTags).Count
if ($missingKeepTagCount -gt 0) {
    $missingKeepMessage = ("Missing keep image tags in current Docker state: {0}" -f ($missingKeepTags -join ', '))
    if ($Apply.IsPresent) {
        throw $missingKeepMessage
    }

    Write-Warning ($missingKeepMessage + '. Continuing in dry-run mode.')
}

$removeImageTags = @()
if ($Mode -eq 'Conservative') {
    $removeImageTags = @($allImageTags | Where-Object {
            $_ -like 'labview-custom-windows:*' -and
            ($KeepImageTags -notcontains $_)
        })
}
else {
    $removeImageTags = @($allImageTags | Where-Object { $KeepImageTags -notcontains $_ })
}

$removeVolumes = @($allVolumes | Where-Object { $KeepVolumes -notcontains $_ })

$removeLogDirs = @()
if ($Mode -eq 'Aggressive' -and (Test-Path -LiteralPath $logRoot -PathType Container)) {
    $removeLogDirs = @(
        Get-ChildItem -LiteralPath $logRoot -Directory | Where-Object {
            -not (Test-StartsWithAny -Value $_.Name -Prefixes $KeepLogPrefixes)
        } | ForEach-Object { $_.FullName }
    )
}

$summary = [ordered]@{
    timestamp_utc             = (Get-Date).ToUniversalTime().ToString('o')
    mode                      = $Mode
    apply                     = $Apply.IsPresent
    repo_root                 = $repoRoot
    run_root                  = $runRoot
    keep_image_tags           = $KeepImageTags
    keep_volumes              = $KeepVolumes
    keep_log_prefixes         = $KeepLogPrefixes
    exited_container_count    = @($exitedContainers).Count
    image_remove_candidates   = $removeImageTags
    volume_remove_candidates  = $removeVolumes
    log_remove_candidates     = $removeLogDirs
}

$summaryPath = Join-Path $runRoot 'summary.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding ascii
$exitedContainers | Set-Content -Path (Join-Path $runRoot 'exited-containers.txt') -Encoding ascii

if (-not $Apply.IsPresent) {
    Write-Host "Cleanup dry-run completed. Summary: $summaryPath"
    exit 0
}

if (@($exitedContainers).Count -gt 0) {
    & docker container prune -f | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Container prune returned a non-zero exit code.'
    }
}

foreach ($tag in $removeImageTags) {
    Remove-ImageTagIfPresent -Tag $tag
}

foreach ($volumeName in $removeVolumes) {
    Remove-VolumeIfPresent -Name $volumeName
}

if ($removeLogDirs.Count -gt 0) {
    foreach ($dir in $removeLogDirs) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
}

Write-Host "Cleanup apply completed. Summary: $summaryPath"
