[CmdletBinding()]
param(
    [string]$ImageTag = 'labview-custom-windows:2020q1-windows-phase2',
    [string]$IconEditorRepoRoot = '',
    [ValidatePattern('^\d{4}$')][string]$LvYear = '2020',
    [ValidateSet('3363')][string]$LvCliPort = '3363',
    [string]$BuildSpecName = 'Editor Packed Library',
    [string]$OutputRelativePath = 'resource/plugins/lv_icon.lvlibp',
    [switch]$KeepContainer,
    [string]$LogRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ContainerStepExitCode = 0

$LvCliPort = [string]$LvCliPort
if ([string]::IsNullOrWhiteSpace($LvCliPort)) {
    $LvCliPort = '3363'
}
$LvCliPort = $LvCliPort.Trim()

function Escape-SingleQuotedString {
    param([Parameter(Mandatory = $true)][string]$Value)

    return ($Value -replace "'", "''")
}

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [int[]]$AllowedExitCodes = @(0),
        [string]$LogPath = ''
    )

    Write-Host ('docker ' + ($Arguments -join ' '))
    $output = & docker @Arguments 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $script:ContainerStepExitCode = $exitCode

    foreach ($line in @($output)) {
        if ($null -eq $line) {
            continue
        }
        $text = [string]$line
        Write-Host $text
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Add-Content -Path $LogPath -Value $text
        }
    }

    if ($AllowedExitCodes -notcontains $exitCode) {
        throw ($Description + ' failed with exit code ' + $exitCode + '.')
    }

    return $exitCode
}

function Invoke-ContainerStep {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$StepName,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$RunLogRoot,
        [int[]]$AllowedExitCodes = @(0)
    )

    $stepLogPath = Join-Path $RunLogRoot ($StepName + '.log')
    New-Item -Path $stepLogPath -ItemType File -Force | Out-Null

    $dockerArgs = @(
        'exec',
        $ContainerName,
        'powershell',
        '-NoProfile',
        '-Command', $Command
    )
    Write-Host ('docker ' + ($dockerArgs -join ' '))
    $output = & docker @dockerArgs 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $script:ContainerStepExitCode = $exitCode

    foreach ($line in @($output)) {
        if ($null -eq $line) {
            continue
        }
        $text = [string]$line
        Add-Content -Path $stepLogPath -Value $text
        Write-Host $text
    }

    if ($AllowedExitCodes -notcontains $exitCode) {
        throw ('Container step ' + $StepName + ' failed with exit code ' + $exitCode + '. See ' + $stepLogPath)
    }

    return $exitCode
}

function Remove-ContainerIfPresent {
    param([string]$ContainerName)

    if ([string]::IsNullOrWhiteSpace($ContainerName)) {
        return
    }

    & docker container inspect $ContainerName *> $null
    if ($LASTEXITCODE -eq 0) {
        & docker rm -f $ContainerName *> $null
    }
}

function Resolve-DefaultIconEditorRepoRoot {
    param([string]$ForkRoot)

    $workspaceRoot = Split-Path -Parent $ForkRoot
    $candidates = @(
        (Join-Path $workspaceRoot 'labview-icon-editor\labview-icon-editor'),
        (Join-Path $workspaceRoot 'labview-icon-editor'),
        (Join-Path $ForkRoot '..')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'lv_icon_editor.lvproj') -PathType Leaf) {
            return (Resolve-Path -Path $candidate -ErrorAction Stop).Path
        }
    }

    return ''
}

$forkRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if ([string]::IsNullOrWhiteSpace($IconEditorRepoRoot)) {
    $IconEditorRepoRoot = Resolve-DefaultIconEditorRepoRoot -ForkRoot $forkRoot
}
if ([string]::IsNullOrWhiteSpace($IconEditorRepoRoot)) {
    throw 'IconEditorRepoRoot was not provided and could not be auto-resolved.'
}

$resolvedIconEditorRepoRoot = (Resolve-Path -Path $IconEditorRepoRoot -ErrorAction Stop).Path
$projectPath = Join-Path $resolvedIconEditorRepoRoot 'lv_icon_editor.lvproj'
if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw ('Project file not found at ' + $projectPath)
}

if ([string]::IsNullOrWhiteSpace($OutputRelativePath)) {
    throw 'OutputRelativePath is required.'
}
$outputRelativeNormalized = ($OutputRelativePath -replace '/', '\').TrimStart('\')
$outputPath = Join-Path $resolvedIconEditorRepoRoot $outputRelativeNormalized
$previousArtifactTimestamp = $null
if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
    $previousArtifactTimestamp = (Get-Item -LiteralPath $outputPath).LastWriteTimeUtc
}

$resolvedLogRoot = if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    Join-Path $forkRoot 'TestResults\agent-logs'
}
elseif ([System.IO.Path]::IsPathRooted($LogRoot)) {
    $LogRoot
}
else {
    Join-Path $forkRoot $LogRoot
}
New-Item -Path $resolvedLogRoot -ItemType Directory -Force | Out-Null

$runTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLogRoot = Join-Path $resolvedLogRoot ('ppl-phase3-' + $runTimestamp)
New-Item -Path $runLogRoot -ItemType Directory -Force | Out-Null

$dockerServerOs = (& docker version --format '{{.Server.Os}}' 2>$null).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query Docker server mode. Ensure Docker Desktop is running.'
}
if ($dockerServerOs -ne 'windows') {
    throw ('Docker server is not in Windows mode. Current server OS: ' + $dockerServerOs)
}

& docker image inspect $ImageTag *> $null
if ($LASTEXITCODE -ne 0) {
    throw ('Image not found locally: ' + $ImageTag)
}

$containerName = 'lv2020x64-ppl-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$volumeArg = $resolvedIconEditorRepoRoot + ':C:\workspace'

$runSucceeded = $false
$failedOperation = 'preflight'
$portListening = $false
$lastExitCode = 0
$failureMessage = ''
$containerCreated = $false
$containerKept = $false

$configureCmdTemplate = @'
$ErrorActionPreference = 'Stop'
$lvIni = 'C:\Program Files\National Instruments\LabVIEW __LV_YEAR__\LabVIEW.ini'
$cliIni = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini'
$port = '__LV_PORT__'
if (-not (Test-Path -LiteralPath $lvIni -PathType Leaf)) { throw ('LabVIEW.ini not found: ' + $lvIni) }
if (-not (Test-Path -LiteralPath $cliIni -PathType Leaf)) { throw ('LabVIEWCLI.ini not found: ' + $cliIni) }
$lvLines = Get-Content -LiteralPath $lvIni
if (($lvLines | Where-Object { $_ -match '^server\.tcp\.enabled=' }).Count -eq 0) { $lvLines += 'server.tcp.enabled=True' } else { $lvLines = $lvLines | ForEach-Object { if ($_ -match '^server\.tcp\.enabled=') { 'server.tcp.enabled=True' } else { $_ } } }
if (($lvLines | Where-Object { $_ -match '^server\.tcp\.port=' }).Count -eq 0) { $lvLines += ('server.tcp.port=' + $port) } else { $lvLines = $lvLines | ForEach-Object { if ($_ -match '^server\.tcp\.port=') { 'server.tcp.port=' + $port } else { $_ } } }
Set-Content -LiteralPath $lvIni -Value $lvLines -Encoding ascii
$cliLines = Get-Content -LiteralPath $cliIni
if (($cliLines | Where-Object { $_ -match '^DefaultPortNumber\s*=' }).Count -eq 0) { $cliLines += ('DefaultPortNumber = ' + $port) } else { $cliLines = $cliLines | ForEach-Object { if ($_ -match '^DefaultPortNumber\s*=') { 'DefaultPortNumber = ' + $port } else { $_ } } }
Set-Content -LiteralPath $cliIni -Value $cliLines -Encoding ascii
$diagRoot = 'C:\ni\temp\phase3-diag'
New-Item -Path $diagRoot -ItemType Directory -Force | Out-Null
@('port=' + $port, 'configured=true') | Set-Content -Path (Join-Path $diagRoot 'port-config.txt') -Encoding ascii
'@

$massCompileCmdTemplate = @'
$ErrorActionPreference = 'Stop'
$lvPath = 'C:\Program Files\National Instruments\LabVIEW __LV_YEAR__\LabVIEW.exe'
$port = '__LV_PORT__'
$target = 'C:\Program Files\National Instruments\LabVIEW __LV_YEAR__\examples\Arrays'
if (-not (Test-Path -LiteralPath $lvPath -PathType Leaf)) { throw ('LabVIEW executable not found: ' + $lvPath) }
if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw ('MassCompile target directory not found: ' + $target) }
# Keep LabVIEW startup deterministic in containers.
Start-Process -FilePath $lvPath -ArgumentList '--headless' -WindowStyle Hidden | Out-Null
$deadline = (Get-Date).AddMinutes(4)
$pattern = ':' + [regex]::Escape($port) + '\s+.*LISTENING'
$isListening = $false
while ((Get-Date) -lt $deadline) {
  $matches = @(netstat -ano | Select-String -Pattern $pattern)
  if ($matches.Count -gt 0) { $isListening = $true; break }
  Start-Sleep -Seconds 2
}
if ($isListening) { Write-Host ('Port listening before MassCompile: ' + $port) } else { Write-Error ('Port not listening before MassCompile: ' + $port); exit 51 }
$cliLines = @(& LabVIEWCLI -LogToConsole TRUE -OperationName MassCompile -DirectoryToCompile $target -LabVIEWPath $lvPath -PortNumber $port -Headless 2>&1)
$cliLines | ForEach-Object { Write-Host $_ }
$exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
$contains350000 = ($cliLines -join "`n") -match '-350000'
if ($contains350000) { Write-Error 'MassCompile reported -350000'; exit 52 }
if ($exitCode -ne 0) { exit $exitCode }
'@

$buildSpecCmdTemplate = @'
$ErrorActionPreference = 'Stop'
$lvPath = 'C:\Program Files\National Instruments\LabVIEW __LV_YEAR__\LabVIEW.exe'
$port = '__LV_PORT__'
$projectPath = 'C:\workspace\lv_icon_editor.lvproj'
$buildSpecName = '__BUILD_SPEC__'
$outputRel = '__OUTPUT_REL__'
$outputPath = Join-Path 'C:\workspace' $outputRel
if (-not (Test-Path -LiteralPath $lvPath -PathType Leaf)) { throw ('LabVIEW executable not found: ' + $lvPath) }
if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) { throw ('Project file not found: ' + $projectPath) }
if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Remove-Item -LiteralPath $outputPath -Force }
Start-Process -FilePath $lvPath -ArgumentList '--headless' -WindowStyle Hidden | Out-Null
$deadline = (Get-Date).AddMinutes(4)
$pattern = ':' + [regex]::Escape($port) + '\s+.*LISTENING'
$isListening = $false
while ((Get-Date) -lt $deadline) {
  $matches = @(netstat -ano | Select-String -Pattern $pattern)
  if ($matches.Count -gt 0) { $isListening = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $isListening) { Write-Error ('Port not listening before ExecuteBuildSpec: ' + $port); exit 61 }
$buildStartUtc = (Get-Date).ToUniversalTime()
$cliLines = @()
$maxAttempts = 2
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
  $cliLines = @(& LabVIEWCLI -LogToConsole TRUE -OperationName ExecuteBuildSpec -ProjectPath $projectPath -BuildSpecName $buildSpecName -TargetName 'My Computer' -LabVIEWPath $lvPath -PortNumber $port 2>&1)
  $cliLines | ForEach-Object { Write-Host $_ }
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  $contains350000 = ($cliLines -join "`n") -match '-350000'
  if (-not $contains350000 -and $exitCode -eq 0) { break }
  if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 8 }
}
if (($cliLines -join "`n") -match '-350000') { Write-Error 'ExecuteBuildSpec reported -350000'; exit 62 }
if ($exitCode -ne 0) { exit $exitCode }
if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { Write-Error ('Build output missing: ' + $outputPath); exit 2 }
$outputItem = Get-Item -LiteralPath $outputPath -ErrorAction Stop
if ($outputItem.LastWriteTimeUtc -lt $buildStartUtc) { Write-Error ('Build output stale: ' + $outputPath); exit 3 }
if ($outputItem.Length -le 0) { Write-Error ('Build output empty: ' + $outputPath); exit 4 }
Write-Host ('Build output: ' + $outputPath + ' (' + $outputItem.Length + ' bytes)')
'@

$diagnosticsCmdTemplate = @'
$ErrorActionPreference = 'Continue'
$port = '__LV_PORT__'
$lvYear = '__LV_YEAR__'
$diagRoot = 'C:\ni\temp\phase3-diag'
New-Item -Path $diagRoot -ItemType Directory -Force | Out-Null
$netstatLines = @(netstat -ano)
$netstatPath = Join-Path $diagRoot 'netstat-ano.txt'
$netstatLines | Set-Content -Path $netstatPath -Encoding ascii
$pattern = ':' + [regex]::Escape($port) + '\s+.*LISTENING'
$listening = @($netstatLines | Select-String -Pattern $pattern)
$portListening = ($listening.Count -gt 0)
@('port=' + $port, 'port_listening=' + $portListening) | Set-Content -Path (Join-Path $diagRoot 'port-listening.txt') -Encoding ascii
if ($portListening) { $listening | ForEach-Object { $_.ToString() } | Set-Content -Path (Join-Path $diagRoot 'port-listening-lines.txt') -Encoding ascii }
Get-Process | Sort-Object ProcessName | Format-Table -AutoSize | Out-String | Set-Content -Path (Join-Path $diagRoot 'process-list.txt') -Encoding ascii
$tempRoot = Join-Path $diagRoot 'lvtemporary'
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'lvtemporary_*.log' -File -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tempRoot $_.Name) -Force }
$userRoot = Join-Path $diagRoot 'labview-user-logs'
New-Item -Path $userRoot -ItemType Directory -Force | Out-Null
$roots = @('C:\Users\ContainerAdministrator\AppData\Local\Temp', 'C:\Users\ContainerAdministrator\AppData\Local', 'C:\Users\ContainerAdministrator\AppData\Roaming')
$patterns = @('LabVIEWCLI*_cur.txt', 'LabVIEW*_cur.txt', 'LabVIEWCLI*.log', 'LabVIEW*.log')
foreach ($root in $roots) {
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
  foreach ($pat in $patterns) {
    Get-ChildItem -Path $root -Recurse -File -Filter $pat -ErrorAction SilentlyContinue | Select-Object -First 200 | ForEach-Object {
      $name = ($_.DirectoryName -replace '[:\\ ]', '_') + '_' + $_.Name
      $dest = Join-Path $userRoot $name
      if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { Copy-Item -LiteralPath $_.FullName -Destination $dest -Force }
    }
  }
}
$lvIni = 'C:\Program Files\National Instruments\LabVIEW ' + $lvYear + '\LabVIEW.ini'
$cliIni = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini'
if (Test-Path -LiteralPath $lvIni -PathType Leaf) { Copy-Item -LiteralPath $lvIni -Destination (Join-Path $diagRoot 'LabVIEW.ini') -Force }
if (Test-Path -LiteralPath $cliIni -PathType Leaf) { Copy-Item -LiteralPath $cliIni -Destination (Join-Path $diagRoot 'LabVIEWCLI.ini') -Force }
'@

$escapedLvYear = Escape-SingleQuotedString -Value $LvYear
$escapedBuildSpecName = Escape-SingleQuotedString -Value $BuildSpecName
$escapedOutputRelativePath = Escape-SingleQuotedString -Value $outputRelativeNormalized

$configureCmd = $configureCmdTemplate.Replace('__LV_YEAR__', $escapedLvYear).Replace('__LV_PORT__', $LvCliPort)
$massCompileCmd = $massCompileCmdTemplate.Replace('__LV_YEAR__', $escapedLvYear).Replace('__LV_PORT__', $LvCliPort)
$buildSpecCmd = $buildSpecCmdTemplate.Replace('__LV_YEAR__', $escapedLvYear).Replace('__LV_PORT__', $LvCliPort).Replace('__BUILD_SPEC__', $escapedBuildSpecName).Replace('__OUTPUT_REL__', $escapedOutputRelativePath)
$diagnosticsCmd = $diagnosticsCmdTemplate.Replace('__LV_YEAR__', $escapedLvYear).Replace('__LV_PORT__', $LvCliPort)

try {
    $failedOperation = 'start-container'
    $dockerRunLog = Join-Path $runLogRoot 'docker-run.log'
    Invoke-DockerCommand -Arguments @('run', '--name', $containerName, '--detach', '--volume', $volumeArg, $ImageTag, 'powershell', '-NoProfile', '-Command', 'Start-Sleep -Seconds 43200') -Description 'start phase3 container' -LogPath $dockerRunLog | Out-Null
    $containerCreated = $true

    $failedOperation = 'configure-port'
    $lastExitCode = Invoke-ContainerStep -ContainerName $containerName -StepName 'configure-port' -Command $configureCmd -RunLogRoot $runLogRoot

    $failedOperation = 'masscompile'
    $lastExitCode = Invoke-ContainerStep -ContainerName $containerName -StepName 'masscompile' -Command $massCompileCmd -RunLogRoot $runLogRoot

    $failedOperation = 'executebuildspec'
    $lastExitCode = Invoke-ContainerStep -ContainerName $containerName -StepName 'executebuildspec' -Command $buildSpecCmd -RunLogRoot $runLogRoot

    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw ('Expected build output not found at ' + $outputPath)
    }

    $artifact = Get-Item -LiteralPath $outputPath -ErrorAction Stop
    if ($artifact.Length -le 0) {
        throw ('Output artifact is empty: ' + $outputPath)
    }
    if (($null -ne $previousArtifactTimestamp) -and ($artifact.LastWriteTimeUtc -le $previousArtifactTimestamp)) {
        throw ('Output artifact timestamp was not updated: ' + $outputPath)
    }

    $failedOperation = 'none'
    $runSucceeded = $true
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    if ($containerCreated) {
        try {
            Invoke-ContainerStep -ContainerName $containerName -StepName 'collect-diagnostics' -Command $diagnosticsCmd -RunLogRoot $runLogRoot -AllowedExitCodes @(0) | Out-Null
            if (-not $KeepContainer.IsPresent) {
                Invoke-DockerCommand -Arguments @('stop', $containerName) -Description 'stop phase3 container before diagnostics copy' | Out-Null
            }
            Invoke-DockerCommand -Arguments @('cp', ($containerName + ':C:\ni\temp\phase3-diag'), $runLogRoot) -Description 'copy diagnostics from container' -LogPath (Join-Path $runLogRoot 'docker-cp-diagnostics.log') | Out-Null
            $portStatusPath = Join-Path $runLogRoot 'phase3-diag\port-listening.txt'
            if (Test-Path -LiteralPath $portStatusPath -PathType Leaf) {
                $statusLine = Get-Content -LiteralPath $portStatusPath | Where-Object { $_ -like 'port_listening=*' } | Select-Object -First 1
                if (-not [string]::IsNullOrWhiteSpace($statusLine)) {
                    $value = ($statusLine -split '=', 2)[1]
                    $portListening = $value -in @('True', 'true', '1')
                }
            }
        }
        catch {
            Write-Warning ('Diagnostics collection failed: ' + $_.Exception.Message)
        }

        if ($KeepContainer.IsPresent) {
            $containerKept = $true
            Write-Host ('Container kept for debugging: ' + $containerName)
        }
        else {
            Remove-ContainerIfPresent -ContainerName $containerName
        }
    }

    $artifactExists = Test-Path -LiteralPath $outputPath -PathType Leaf
    $artifactSize = if ($artifactExists) { (Get-Item -LiteralPath $outputPath).Length } else { 0 }
    $summary = [ordered]@{
        timestamp_utc            = (Get-Date).ToUniversalTime().ToString('o')
        image_tag                = $ImageTag
        icon_editor_repo_root    = $resolvedIconEditorRepoRoot
        lv_year                  = $LvYear
        lv_cli_port              = $LvCliPort
        build_spec_name          = $BuildSpecName
        output_relative_path     = $outputRelativeNormalized
        output_path              = $outputPath
        run_log_root             = $runLogRoot
        container_name           = $containerName
        container_kept           = $containerKept
        run_succeeded            = $runSucceeded
        failed_operation         = $failedOperation
        last_step_exit_code      = $script:ContainerStepExitCode
        port_listening           = $portListening
        artifact_exists          = $artifactExists
        artifact_size_bytes      = $artifactSize
        keep_container_requested = $KeepContainer.IsPresent
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $runLogRoot 'summary.json') -Encoding ascii
}

if (-not $runSucceeded) {
    $exitCodeText = if ($script:ContainerStepExitCode -eq 0) { 'n/a' } else { [string]$script:ContainerStepExitCode }
    Write-Host ('Failure summary: exit_code=' + $exitCodeText + '; operation=' + $failedOperation + '; logs=' + $runLogRoot + '; port_listening=' + $portListening)
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = 'Phase 3 build failed.'
    }
    throw $failureMessage
}

$finalArtifact = Get-Item -LiteralPath $outputPath -ErrorAction Stop
Write-Host ('Phase 3 build succeeded. Artifact: ' + $finalArtifact.FullName + ' (' + $finalArtifact.Length + ' bytes).')
Write-Host ('Logs: ' + $runLogRoot)
