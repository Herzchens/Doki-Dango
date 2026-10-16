[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$ProjectRoot = Join-Path $RepoRoot 'android\spikes\firebase-messaging\android'
$ArtifactsRoot = Join-Path $RepoRoot 'artifacts\b'
$ToolingRoot = Join-Path $ArtifactsRoot 'tooling'
$PackageRoot = Join-Path $ArtifactsRoot 'package'
$GradleVersion = '9.1.0'
$GradleZip = Join-Path $ToolingRoot "gradle-$GradleVersion-bin.zip"
$GradleHome = Join-Path $ToolingRoot "gradle-$GradleVersion"
$GradleUrl = "https://services.gradle.org/distributions/gradle-$GradleVersion-bin.zip"
$GradleSha256 = 'a17ddd85a26b6a7f5ddb71ff8b05fc5104c0202c6e64782429790c933686c806'

function Resolve-AndroidSdkRoot {
    foreach ($candidate in @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Android SDK root not found. Set ANDROID_SDK_ROOT/ANDROID_HOME or install the SDK under %LOCALAPPDATA%\Android\Sdk.'
}

function Ensure-Gradle {
    New-Item -ItemType Directory -Force -Path $ToolingRoot | Out-Null

    if (-not (Test-Path -LiteralPath $GradleHome)) {
        if (-not (Test-Path -LiteralPath $GradleZip)) {
            Write-Host "Downloading Gradle $GradleVersion..."
            Invoke-WebRequest -UseBasicParsing -Uri $GradleUrl -OutFile $GradleZip
        }

        $actualHash = (Get-FileHash -LiteralPath $GradleZip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $GradleSha256) {
            Remove-Item -Force -LiteralPath $GradleZip -ErrorAction SilentlyContinue
            throw "Gradle ZIP SHA-256 mismatch. Expected $GradleSha256, got $actualHash."
        }

        Expand-Archive -LiteralPath $GradleZip -DestinationPath $ToolingRoot -Force
    }

    $gradleBat = Join-Path $GradleHome 'bin\gradle.bat'
    if (-not (Test-Path -LiteralPath $gradleBat)) {
        throw "Gradle executable not found after extraction: $gradleBat"
    }

    return $gradleBat
}

$androidSdk = Resolve-AndroidSdkRoot
$env:ANDROID_SDK_ROOT = $androidSdk
$env:ANDROID_HOME = $androidSdk

$gradle = Ensure-Gradle
New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null

Write-Host "Android SDK: $androidSdk"
Write-Host "Gradle: $gradle"

& $gradle --no-daemon --stacktrace -p $ProjectRoot :app:assembleDebug
if ($LASTEXITCODE -ne 0) {
    throw "Gradle build failed with exit code $LASTEXITCODE"
}

$sourceApk = Join-Path $ProjectRoot 'app\build\outputs\apk\debug\app-debug.apk'
if (-not (Test-Path -LiteralPath $sourceApk)) {
    throw "Expected debug APK not found: $sourceApk"
}

$outputApk = Join-Path $PackageRoot 'DokiDango.BHarness-debug.apk'
Copy-Item -Force -LiteralPath $sourceApk -Destination $outputApk

Write-Host "Built B Android harness: $outputApk"
