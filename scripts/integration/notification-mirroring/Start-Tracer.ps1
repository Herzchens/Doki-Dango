[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [string]$A1EvidencePath,

    [string]$MarkerPrefix = 'DOKI-A1-',

    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$SendScript = Join-Path $RepoRoot 'scripts\test\android-fcm\Send-TestMessage.ps1'
$EvidenceRoot = Join-Path $RepoRoot 'artifacts\a2\evidence'
$PackageName = 'dev.dokidango.bharness'
$FidPath = Join-Path $env:LOCALAPPDATA 'Doki-Dango\B\secrets\fid.txt'
$AccessTokenPath = Join-Path $env:LOCALAPPDATA 'Doki-Dango\B\secrets\access-token.json'

function Resolve-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($root in @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    )) {
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

function Resolve-A1EvidencePath {
    if ($A1EvidencePath) {
        if (-not (Test-Path -LiteralPath $A1EvidencePath)) {
            throw "A1 evidence file not found: $A1EvidencePath"
        }
        return (Resolve-Path -LiteralPath $A1EvidencePath).Path
    }

    $root = Join-Path $env:LOCALAPPDATA 'Doki-Dango\A1\evidence'
    if (-not (Test-Path -LiteralPath $root)) {
        throw "A1 evidence directory not found: $root"
    }

    $latest = Get-ChildItem -LiteralPath $root -Filter 'a1-*.jsonl' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No A1 evidence file found under $root"
    }

    return $latest.FullName
}

function Read-JsonLines([string]$Path) {
    $records = @()
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $records += ($line | ConvertFrom-Json)
        }
        catch {
            throw "Invalid JSONL in ${Path}: $($_.Exception.Message)"
        }
    }
    return @($records)
}

function Get-AndroidEvidence([string]$Adb) {
    $raw = (& $Adb exec-out run-as $PackageName cat files/b-evidence.jsonl 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read B runtime evidence from the Android debug app.'
    }

    $records = @()
    foreach ($line in ($raw -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $records += ($line | ConvertFrom-Json)
        }
        catch {
            throw "Invalid Android JSONL evidence: $($_.Exception.Message)"
        }
    }

    return @($records)
}

if (-not (Test-Path -LiteralPath $SendScript)) {
    throw "B sender script not found: $SendScript"
}
if (-not (Test-Path -LiteralPath $FidPath)) {
    throw "B FID secret not found: $FidPath"
}
if (-not (Test-Path -LiteralPath $AccessTokenPath)) {
    throw "B OAuth token not found: $AccessTokenPath"
}

$adb = Resolve-Adb
Assert-OneAuthorizedDevice $adb

$a1Path = Resolve-A1EvidencePath
$a1Records = Read-JsonLines $a1Path

$launch = $a1Records |
    Where-Object {
        $_.operation -eq 'harness_launch' -and
        $_.outcome -eq 'success'
    } |
    Select-Object -Last 1

if (-not $launch) {
    throw 'A1 evidence has no successful harness_launch record.'
}

$packageForm = [string]$launch.data.PackageForm
if ($packageForm -ne 'packaged') {
    throw "A2.0 requires the packaged A1 listener path; observed package form '$packageForm'."
}

$subscription = $a1Records |
    Where-Object {
        $_.operation -eq 'NotificationChanged.subscribe' -and
        $_.outcome -eq 'success'
    } |
    Select-Object -Last 1

if (-not $subscription) {
    throw 'A1 event listener is not proven subscribed in the current evidence file. Start Events in the packaged A1 harness first.'
}

$startIndex = $a1Records.Count
$startedUtc = [DateTimeOffset]::UtcNow
$deadline = $startedUtc.AddSeconds($TimeoutSeconds)

Write-Host "A2.0 tracer started: $($startedUtc.ToString('o'))"
Write-Host "A1 evidence: $a1Path"
Write-Host 'Waiting for a NEW synthetic Windows notification observed by the packaged A1 listener...'

$windowsRecord = $null

while ([DateTimeOffset]::UtcNow -lt $deadline -and -not $windowsRecord) {
    Start-Sleep -Milliseconds 250
    $current = Read-JsonLines $a1Path

    if ($current.Count -le $startIndex) {
        continue
    }

    foreach ($record in $current[$startIndex..($current.Count - 1)]) {
        if (
            $record.operation -eq 'notification_event_snapshot' -and
            $record.outcome -eq 'observed' -and
            $record.data.textInspection -eq 'allowed_source' -and
            $record.data.markerMatched -eq $true -and
            [string]$record.data.title -like "$MarkerPrefix*"
        ) {
            $windowsRecord = $record
            break
        }
    }

    $startIndex = $current.Count
}

if (-not $windowsRecord) {
    throw "Timed out after $TimeoutSeconds seconds waiting for a synthetic A1 event snapshot."
}

$title = [string]$windowsRecord.data.title
$markerMatch = [regex]::Match($title, '^DOKI-A1-(\d{13})-([0-9a-fA-F]+)')
if (-not $markerMatch.Success) {
    throw "Synthetic A1 title does not contain the expected timestamped marker: $title"
}

$sourceEpochMs = [Int64]$markerMatch.Groups[1].Value
$sourceSuffix = $markerMatch.Groups[2].Value.ToLowerInvariant()
$sourceCreatedUtc = [DateTimeOffset]::FromUnixTimeMilliseconds($sourceEpochMs)
$listenerObservedUtc = [DateTimeOffset]::Parse([string]$windowsRecord.timestampUtc)
$testId = "DOKI-B-A20-$sourceEpochMs-$sourceSuffix"

Write-Host "Windows source marker: $($markerMatch.Value)"
Write-Host "Listener observed: $($listenerObservedUtc.ToString('o'))"
Write-Host "Sending A2.0 test ID: $testId"

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SendScript -ProjectId $ProjectId -TestId $testId

if ($LASTEXITCODE -ne 0) {
    throw "B sender failed with exit code $LASTEXITCODE"
}

$sendEvidencePath = Join-Path $RepoRoot ("artifacts\b\evidence\send-{0}.json" -f ($testId -replace '[^A-Za-z0-9_.-]', '_'))
if (-not (Test-Path -LiteralPath $sendEvidencePath)) {
    throw "Expected sender evidence not found: $sendEvidencePath"
}

$sendEvidence = Get-Content -LiteralPath $sendEvidencePath -Raw | ConvertFrom-Json
if (-not $sendEvidence.accepted) {
    throw "FCM sender did not accept A2.0 test ID $testId"
}

$fcmAcceptedUtc = [DateTimeOffset]::Parse([string]$sendEvidence.timestampUtc)
$androidDeadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
$callback = $null
$notification = $null

while ([DateTimeOffset]::UtcNow -lt $androidDeadline) {
    $androidRecords = Get-AndroidEvidence $adb

    $callback = $androidRecords |
        Where-Object {
            $_.operation -eq 'onMessageReceived' -and
            $_.outcome -eq 'success' -and
            [string]$_.data.testId -eq $testId
        } |
        Select-Object -Last 1

    $notification = $androidRecords |
        Where-Object {
            $_.operation -eq 'local_notification' -and
            $_.outcome -eq 'posted' -and
            [string]$_.data.testId -eq $testId
        } |
        Select-Object -Last 1

    if ($callback -and $notification) {
        break
    }

    Start-Sleep -Milliseconds 500
}

if (-not $callback) {
    throw "Android callback was not observed for A2.0 test ID $testId"
}
if (-not $notification) {
    throw "Android local notification was not observed for A2.0 test ID $testId"
}

$callbackUtc = [DateTimeOffset]::Parse([string]$callback.timestampUtc)
$notificationUtc = [DateTimeOffset]::Parse([string]$notification.timestampUtc)

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$outputPath = Join-Path $EvidenceRoot ("a20-{0}.json" -f ($testId -replace '[^A-Za-z0-9_.-]', '_'))

$result = [ordered]@{
    phase = 'A2.0'
    result = 'PASS'
    testId = $testId
    source = [ordered]@{
        appDisplayName = [string]$windowsRecord.data.appDisplayName
        syntheticMarker = $markerMatch.Value
        createdUtc = $sourceCreatedUtc.ToString('o')
    }
    listener = [ordered]@{
        packageForm = $packageForm
        observedUtc = $listenerObservedUtc.ToString('o')
        operation = 'notification_event_snapshot'
    }
    sender = [ordered]@{
        accepted = [bool]$sendEvidence.accepted
        httpStatus = [int]$sendEvidence.httpStatus
        acceptedUtc = $fcmAcceptedUtc.ToString('o')
    }
    android = [ordered]@{
        callbackUtc = $callbackUtc.ToString('o')
        foreground = [bool]$callback.data.foreground
        localNotificationUtc = $notificationUtc.ToString('o')
        localNotificationStatus = [string]$notification.data.status
    }
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputPath -Encoding utf8

Write-Host 'A2.0 E2E PASS'
Write-Host "Evidence: $outputPath"
Write-Host "Windows source created: $($sourceCreatedUtc.ToString('o'))"
Write-Host "Listener observed:      $($listenerObservedUtc.ToString('o'))"
Write-Host "FCM accepted:           $($fcmAcceptedUtc.ToString('o'))"
Write-Host "Android callback:       $($callbackUtc.ToString('o'))"
Write-Host "Local notification:     $($notificationUtc.ToString('o'))"
