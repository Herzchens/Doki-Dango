[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$LogDir = Join-Path $env:LOCALAPPDATA 'Doki-Dango\Host\logs'

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
    if (-not (Test-Path -LiteralPath $LogDir)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $LogDir -File |
            Select-Object -ExpandProperty FullName
    )
}

function Wait-NewLog {
    param(
        [string[]]$Before,
        [int]$TimeoutSeconds = 10
    )

    $known = @{}
    foreach ($path in $Before) {
        $known[$path] = $true
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue |
            Where-Object { -not $known.ContainsKey($_.FullName) } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($candidate) {
            return $candidate
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Timed out waiting for a new Host log under $LogDir"
}

function Wait-LogPatterns {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns,

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

            $allMatched = $true
            foreach ($pattern in $Patterns) {
                if ($content -notmatch [regex]::Escape($pattern)) {
                    $allMatched = $false
                    break
                }
            }

            if ($allMatched) {
                return $content
            }
        }

        Start-Sleep -Milliseconds 200
    }

    $missing = @(
        foreach ($pattern in $Patterns) {
            if ($content -notmatch [regex]::Escape($pattern)) {
                $pattern
            }
        }
    )

    throw "Timed out waiting for Host log '$Path' to contain: $($missing -join ', ')"
}

function Wait-HostCount {
    param(
        [int]$Expected,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $processes = @(Get-Process -Name dokidango -ErrorAction SilentlyContinue)
        if ($processes.Count -eq $Expected) {
            return $processes
        }

        Start-Sleep -Milliseconds 200
    }

    $actual = @(Get-Process -Name dokidango -ErrorAction SilentlyContinue)
    throw "Expected $Expected dokidango process(es), found $($actual.Count)"
}

$package = Get-InstalledPackage
$Aumid = "shell:AppsFolder\$($package.PackageFamilyName)!Host"

Write-Host '=== TEST: WINDOWS HOST LIFECYCLE ==='

Stop-Process -Name dokidango -Force -ErrorAction SilentlyContinue
$null = Wait-HostCount -Expected 0

Write-Host "1. Launching Primary Packaged Host: $Aumid"
$beforePrimaryLogs = Get-LogSnapshot
Start-Process $Aumid

$primaryProcesses = Wait-HostCount -Expected 1
$primaryPid = $primaryProcesses[0].Id
$primaryLog = Wait-NewLog -Before $beforePrimaryLogs
$primaryLogContent = Wait-LogPatterns -Path $primaryLog.FullName -Patterns @(
    'operation=lifecycle status=starting',
    'operation=listener_ready status=success',
    'operation=lifecycle status=running'
)

Write-Host "Primary lifecycle verification: PASS (PID $primaryPid)"

Write-Host '2. Launching Duplicate Packaged Host while Primary is running...'
$beforeDuplicateLogs = Get-LogSnapshot
Start-Process $Aumid

$afterDuplicateProcesses = Wait-HostCount -Expected 1
if ($afterDuplicateProcesses[0].Id -ne $primaryPid) {
    throw "Primary process PID changed. Expected $primaryPid, got $($afterDuplicateProcesses[0].Id)"
}

$duplicateLog = Wait-NewLog -Before $beforeDuplicateLogs
$duplicateLogContent = Wait-LogPatterns -Path $duplicateLog.FullName -Patterns @(
    'operation=lifecycle status=already_running'
)

if ($duplicateLogContent -match 'operation=listener_ready') {
    throw "Duplicate log unexpectedly contains 'operation=listener_ready'"
}
if ($duplicateLogContent -match 'operation=access') {
    throw "Duplicate log unexpectedly contains 'operation=access'"
}
if ($duplicateLogContent -match 'operation=poll') {
    throw "Duplicate log unexpectedly contains 'operation=poll'"
}

Write-Host "Duplicate rejected cleanly; Primary PID $primaryPid remains sole active process: PASS"

Write-Host '3. Stopping Primary Host to verify singleton release...'
Stop-Process -Id $primaryPid -Force
$null = Wait-HostCount -Expected 0

Write-Host '4. Relaunching Packaged Host...'
$beforeRestartLogs = Get-LogSnapshot
Start-Process $Aumid

$restartProcesses = Wait-HostCount -Expected 1
$restartPid = $restartProcesses[0].Id
$restartLog = Wait-NewLog -Before $beforeRestartLogs
$restartLogContent = Wait-LogPatterns -Path $restartLog.FullName -Patterns @(
    'operation=lifecycle status=starting',
    'operation=listener_ready status=success',
    'operation=lifecycle status=running'
)

if ($restartLogContent -match 'operation=lifecycle status=already_running') {
    throw "Restart log contains a stale 'already_running' state"
}

Write-Host "Singleton release and reacquire verification: PASS (PID $restartPid)"
Write-Host '=== ALL LIFECYCLE TESTS PASSED ==='
