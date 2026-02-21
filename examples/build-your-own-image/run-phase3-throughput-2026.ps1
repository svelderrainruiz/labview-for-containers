[CmdletBinding()]
param(
    [string]$IconEditorRepoRoot = '',
    [string]$OutputRelativePath = 'resource/plugins/lv_icon.lvlibp',
    [ValidateSet('3363')][string]$LvCliPort = '3363',
    [switch]$KeepContainer,
    [string]$LogRoot = 'TestResults/agent-logs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DefaultIconEditorRepoRoot {
    param([Parameter(Mandatory = $true)][string]$ForkRoot)

    $workspaceRoot = Split-Path -Parent $ForkRoot
    $candidates = @(
        (Join-Path $workspaceRoot 'labview-icon-editor\labview-icon-editor'),
        (Join-Path $workspaceRoot 'labview-icon-editor')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'lv_icon_editor.lvproj') -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }

    return ''
}

$imageTag = 'nationalinstruments/labview:2026q1-windows'
$lvYear = '2026'
$buildSpecName = 'Editor Packed Library'

$forkRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if ([string]::IsNullOrWhiteSpace($LvCliPort)) {
    $LvCliPort = '3363'
}
$LvCliPort = $LvCliPort.Trim()

if ([string]::IsNullOrWhiteSpace($IconEditorRepoRoot)) {
    $IconEditorRepoRoot = Resolve-DefaultIconEditorRepoRoot -ForkRoot $forkRoot
}
if ([string]::IsNullOrWhiteSpace($IconEditorRepoRoot)) {
    throw 'IconEditorRepoRoot was not provided and could not be auto-resolved.'
}
$resolvedIconEditorRepoRoot = (Resolve-Path -LiteralPath $IconEditorRepoRoot -ErrorAction Stop).Path

$projectPath = Join-Path $resolvedIconEditorRepoRoot 'lv_icon_editor.lvproj'
if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "Project file not found: $projectPath"
}

try {
    [xml]$projectXml = Get-Content -LiteralPath $projectPath -Raw -ErrorAction Stop
}
catch {
    throw "Unable to parse project XML at $projectPath. $($_.Exception.Message)"
}

$buildItems = @($projectXml.SelectNodes("//Item[@Type='Build']"))
$buildSpecNames = @($buildItems | ForEach-Object { [string]$_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($buildSpecNames -notcontains $buildSpecName) {
    $knownNames = if ($buildSpecNames.Count -gt 0) { $buildSpecNames -join ', ' } else { '<none>' }
    throw "Build specification '$buildSpecName' was not found in $projectPath. Known build specs: $knownNames"
}

$dockerServerOs = (& docker version --format '{{.Server.Os}}' 2>$null).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query Docker server mode. Ensure Docker Desktop is running.'
}
if ($dockerServerOs -ne 'windows') {
    throw "Docker server is not in Windows mode. Current server OS: $dockerServerOs"
}

& docker image inspect $imageTag > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Image not found locally: $imageTag"
}

$resolvedLogRoot = if ([System.IO.Path]::IsPathRooted($LogRoot)) { $LogRoot } else { Join-Path $forkRoot $LogRoot }
New-Item -Path $resolvedLogRoot -ItemType Directory -Force | Out-Null

$runTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$throughputRoot = Join-Path $resolvedLogRoot ("phase3-throughput-2026-{0}" -f $runTimestamp)
New-Item -Path $throughputRoot -ItemType Directory -Force | Out-Null

@(
    "timestamp=$((Get-Date).ToString('o'))",
    "image_tag=$imageTag",
    "lv_year=$lvYear",
    "lv_cli_port=$LvCliPort",
    "icon_editor_repo_root=$resolvedIconEditorRepoRoot",
    "project_path=$projectPath",
    "build_spec_name=$buildSpecName",
    "output_relative_path=$OutputRelativePath"
) | Set-Content -Path (Join-Path $throughputRoot 'preflight.txt') -Encoding ascii

$innerScript = Join-Path $PSScriptRoot 'build-lv-icon-ppl-from-image.ps1'
if (-not (Test-Path -LiteralPath $innerScript -PathType Leaf)) {
    throw "Inner Phase 3 script not found: $innerScript"
}

$innerParams = @{
    ImageTag          = $imageTag
    IconEditorRepoRoot = $resolvedIconEditorRepoRoot
    LvYear            = $lvYear
    LvCliPort         = $LvCliPort
    BuildSpecName     = $buildSpecName
    OutputRelativePath = $OutputRelativePath
    LogRoot           = $throughputRoot
}
if ($KeepContainer.IsPresent) {
    $innerParams['KeepContainer'] = $true
}

& $innerScript @innerParams

$latestRun = Get-ChildItem -LiteralPath $throughputRoot -Directory -Filter 'ppl-phase3-*' -ErrorAction Stop |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if ($null -eq $latestRun) {
    throw "No ppl-phase3 run folder was produced under $throughputRoot"
}

$summaryPath = Join-Path $latestRun.FullName 'summary.json'
if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    throw "Summary file missing: $summaryPath"
}

$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
if (-not $summary.run_succeeded) {
    throw "Throughput run did not succeed. Summary: $summaryPath"
}
if (-not $summary.artifact_exists) {
    throw "Artifact was not produced. Summary: $summaryPath"
}
if ([int64]$summary.artifact_size_bytes -le 0) {
    throw "Artifact is empty. Summary: $summaryPath"
}

Write-Host ('Throughput run root: ' + $throughputRoot)
Write-Host ('Run summary: ' + $summaryPath)
Write-Host ('Artifact: ' + $summary.output_path)
