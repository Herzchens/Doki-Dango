[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$HostLogDir = Join-Path $env:LOCALAPPDATA 'Doki-Dango\Host\logs'
$UiLogDir = Join-Path $env:LOCALAPPDATA 'Doki-Dango\UI\logs'

function Get-InstalledPackage {
    $package = Get-AppxPackage -Name 'ItzHerzchen.DokiDango' |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $package) {
        throw 'Doki-Dango package is not installed for the current user.'
    }

    return $package
}

function Get-LogSnapshot {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Directory -File |
            Select-Object -ExpandProperty FullName
    )
}

function Wait-NewLog {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string[]]$Before,
        [int]$TimeoutSeconds = 10
    )

    $known = @{}
    foreach ($path in $Before) {
        $known[$path] = $true
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
            Where-Object { -not $known.ContainsKey($_.FullName) } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($candidate) {
            return $candidate
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Timed out waiting for a new log under $Directory"
}

function Wait-LogPattern {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $content = ''

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) {
                $content = ''
            }

            if ($content -match [regex]::Escape($Pattern)) {
                return $content
            }
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Timed out waiting for '$Pattern' in $Path"
}

function Wait-ProcessCount {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Expected,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $processes = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
        if ($processes.Count -eq $Expected) {
            return $processes
        }

        Start-Sleep -Milliseconds 200
    }

    $actual = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    throw "Expected $Expected process(es) named $Name, found $($actual.Count)"
}

$package = Get-InstalledPackage
$hostAumid = "shell:AppsFolder\$($package.PackageFamilyName)!Host"
$uiAumid = "shell:AppsFolder\$($package.PackageFamilyName)!UI"
$uiExe = Join-Path $package.InstallLocation 'dokidango-ui.exe'
$uiExeForLog = $uiExe.Replace('\', '\\')

if (-not (Test-Path -LiteralPath $uiExe)) {
    throw "Packaged UI executable is missing: $uiExe"
}

Stop-Process -Name dokidango -Force -ErrorAction SilentlyContinue
Stop-Process -Name dokidango-ui -Force -ErrorAction SilentlyContinue
$null = Wait-ProcessCount -Name 'dokidango' -Expected 0
$null = Wait-ProcessCount -Name 'dokidango-ui' -Expected 0

Write-Host '=== TEST: WINDOWS HOST/UI PROCESS SPLIT ==='

$beforeHostLogs = Get-LogSnapshot -Directory $HostLogDir
Start-Process $hostAumid

$hostProcesses = Wait-ProcessCount -Name 'dokidango' -Expected 1
$hostPid = $hostProcesses[0].Id
$hostLog = Wait-NewLog -Directory $HostLogDir -Before $beforeHostLogs
$null = Wait-LogPattern -Path $hostLog.FullName -Pattern 'operation=listener_ready status=success'

Write-Host "Primary Host ready (PID $hostPid)"

$beforeUiLogs = Get-LogSnapshot -Directory $UiLogDir
Start-Process $uiAumid

$uiLog = Wait-NewLog -Directory $UiLogDir -Before $beforeUiLogs
$uiContent = Wait-LogPattern -Path $uiLog.FullName -Pattern 'operation=ui_process role=settings_surface status=exiting reason=bootstrap_complete exit_code=0'

if ($uiContent -notmatch 'operation=ui_process role=settings_surface status=started') {
    throw 'UI log is missing the started marker.'
}

$uiPidMatch = [regex]::Match($uiContent, 'status=started pid=(\d+)')
if (-not $uiPidMatch.Success) {
    throw 'UI log is missing the started process ID.'
}
$uiPid = [int]$uiPidMatch.Groups[1].Value

if ($uiPid -eq $hostPid) {
    throw "UI PID unexpectedly matches Host PID $hostPid."
}
if ($uiContent -notmatch [regex]::Escape($uiExeForLog)) {
    throw "UI log does not identify the installed package executable path: $uiExe"
}
if ($uiContent -match 'operation=access|operation=poll|operation=listener_ready') {
    throw 'UI process unexpectedly performed Host notification-listener work.'
}

$null = Wait-ProcessCount -Name 'dokidango-ui' -Expected 0
$hostAfterUi = Wait-ProcessCount -Name 'dokidango' -Expected 1
if ($hostAfterUi[0].Id -ne $hostPid) {
    throw "Host PID changed after UI exit. Expected $hostPid, got $($hostAfterUi[0].Id)."
}

Write-Host "UI process exited independently (PID $uiPid); Host PID $hostPid remains active: PASS"

$beforeSecondUiLogs = Get-LogSnapshot -Directory $UiLogDir
Start-Process $uiAumid

$secondUiLog = Wait-NewLog -Directory $UiLogDir -Before $beforeSecondUiLogs
$secondUiContent = Wait-LogPattern -Path $secondUiLog.FullName -Pattern 'operation=ui_process role=settings_surface status=exiting reason=bootstrap_complete exit_code=0'

$secondPidMatch = [regex]::Match($secondUiContent, 'status=started pid=(\d+)')
if (-not $secondPidMatch.Success) {
    throw 'Second UI log is missing the started process ID.'
}
$secondUiPid = [int]$secondPidMatch.Groups[1].Value

if ($secondUiPid -eq $hostPid) {
    throw "Second UI PID unexpectedly matches Host PID $hostPid."
}
if ($secondUiContent -notmatch [regex]::Escape($uiExeForLog)) {
    throw "Second UI log does not identify the installed package executable path: $uiExe"
}

$null = Wait-ProcessCount -Name 'dokidango-ui' -Expected 0
$hostAfterSecondUi = Wait-ProcessCount -Name 'dokidango' -Expected 1
if ($hostAfterSecondUi[0].Id -ne $hostPid) {
    throw "Host PID changed after second UI exit. Expected $hostPid, got $($hostAfterSecondUi[0].Id)."
}

Write-Host "Second UI process launch completed independently (PID $secondUiPid): PASS"

Stop-Process -Id $hostPid -Force
$null = Wait-ProcessCount -Name 'dokidango' -Expected 0

Write-Host '=== ALL HOST/UI PROCESS SPLIT TESTS PASSED ==='
