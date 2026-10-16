[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ExpectedTaskId = 'DokiDangoHostStartup'
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

function Wait-LogPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

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

    throw "Timed out waiting for Host log '$Path' to contain '$Pattern'"
}

$package = Get-InstalledPackage
$manifestPath = Join-Path $package.InstallLocation 'AppxManifest.xml'
[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw

$ns = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
$ns.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
$ns.AddNamespace('desktop', 'http://schemas.microsoft.com/appx/manifest/desktop/windows10')

$extension = $manifest.SelectSingleNode(
    '/f:Package/f:Applications/f:Application/f:Extensions/desktop:Extension[@Category="windows.startupTask"]',
    $ns
)
if (-not $extension) {
    throw 'Installed package does not declare windows.startupTask.'
}

$startupTask = $extension.SelectSingleNode('desktop:StartupTask', $ns)
if (-not $startupTask) {
    throw 'Installed package startup extension has no desktop:StartupTask.'
}

if ($extension.Executable -ne 'dokidango.exe') {
    throw "Unexpected startup executable: $($extension.Executable)"
}
if ($extension.EntryPoint -ne 'Windows.FullTrustApplication') {
    throw "Unexpected startup entry point: $($extension.EntryPoint)"
}
if ($startupTask.TaskId -ne $ExpectedTaskId) {
    throw "Unexpected startup task ID: $($startupTask.TaskId)"
}
if ($startupTask.Enabled -ne 'true') {
    throw "Startup task is not enabled by default: $($startupTask.Enabled)"
}
if ($startupTask.DisplayName -ne 'Doki-Dango') {
    throw "Unexpected startup display name: $($startupTask.DisplayName)"
}

Stop-Process -Name dokidango -Force -ErrorAction SilentlyContinue

$beforeLogs = Get-LogSnapshot
$aumid = "shell:AppsFolder\$($package.PackageFamilyName)!Host"
Start-Process $aumid

$deadline = (Get-Date).AddSeconds(10)
$hostProcess = $null
while ((Get-Date) -lt $deadline) {
    $hostProcess = Get-Process -Name dokidango -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hostProcess) {
        break
    }

    Start-Sleep -Milliseconds 200
}

if (-not $hostProcess) {
    throw 'Packaged Host did not start.'
}

$newLog = Wait-NewLog -Before $beforeLogs
$expectedStartupLine = "operation=startup_task task_id=`"$ExpectedTaskId`" state=Enabled"
$logContent = Wait-LogPattern -Path $newLog.FullName -Pattern $expectedStartupLine

if ($logContent -notmatch 'operation=listener_ready status=success') {
    $logContent = Wait-LogPattern -Path $newLog.FullName -Pattern 'operation=listener_ready status=success'
}

Write-Host "Installed startup task registration: PASS ($ExpectedTaskId)"
Write-Host "Startup task state: Enabled"
Write-Host "Packaged Host PID: $($hostProcess.Id)"
