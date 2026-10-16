[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$ApkPath = Join-Path $RepoRoot 'artifacts\android\firebase-messaging\package\DokiDango.BHarness-debug.apk'
$PackageName = 'dev.dokidango.bharness'

function Resolve-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($root in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if ($root) {
            $candidate = Join-Path $root 'platform-tools\adb.exe'
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    throw 'adb.exe not found.'
}

function Assert-OneAuthorizedDevice([string]$Adb) {
    $lines = @(& $Adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\S' })
    $authorized = @($lines | Where-Object { $_ -match '\tdevice$' })
    $unauthorized = @($lines | Where-Object { $_ -match '\tunauthorized$' })

    if ($unauthorized.Count -gt 0) {
        throw 'ADB device is unauthorized. Accept the RSA prompt on the phone and retry.'
    }
    if ($authorized.Count -ne 1) {
        throw "Expected exactly one authorized ADB device; found $($authorized.Count)."
    }
}

if (-not (Test-Path -LiteralPath $ApkPath)) {
    throw "APK not found: $ApkPath. Run android\spikes\firebase-messaging\scripts\Build.ps1 first."
}

$adb = Resolve-Adb
Assert-OneAuthorizedDevice $adb

& $adb install -r $ApkPath
if ($LASTEXITCODE -ne 0) {
    throw "adb install failed with exit code $LASTEXITCODE"
}

& $adb shell am start -n "$PackageName/.MainActivity" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not start $PackageName"
}

Write-Host 'Installed and launched Doki-Dango B Harness.'
