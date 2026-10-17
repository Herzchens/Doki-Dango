[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [string]$CredentialPath = (Join-Path $env:LOCALAPPDATA 'Doki-Dango\Host\credentials\firebase-service-account.dpapi'),

    [string]$FidPath = (Join-Path $env:LOCALAPPDATA 'Doki-Dango\FirebaseMessaging\secrets\fid.txt'),

    [string]$ListenerEvidencePath,

    [string]$MarkerPrefix = 'DOKI-NOTIFICATION-',

    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$HostSenderScript = Join-Path $RepoRoot 'windows\tests\host\Test-ProductionFcmSender.ps1'
$EvidenceRoot = Join-Path $RepoRoot 'artifacts\integration\notification-mirroring\evidence'
$PackageName = 'dev.dokidango.firebase.messaging'

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

function Resolve-ListenerEvidencePath {
    if ($ListenerEvidencePath) {
        if (-not (Test-Path -LiteralPath $ListenerEvidencePath)) {
            throw "Notification listener evidence file not found: $ListenerEvidencePath"
        }
        return (Resolve-Path -LiteralPath $ListenerEvidencePath).Path
    }

    $root = Join-Path $env:LOCALAPPDATA 'Doki-Dango\NotificationListenerDotNet\evidence'
    if (-not (Test-Path -LiteralPath $root)) {
        throw "Notification listener evidence directory not found: $root"
    }

    $latest = Get-ChildItem -LiteralPath $root -Filter 'notification-listener-dotnet-*.jsonl' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No notification listener evidence file found under $root"
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
    $raw = (& $Adb exec-out run-as $PackageName cat files/firebase-messaging-evidence.jsonl 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read Firebase Messaging runtime evidence from the Android debug app.'
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

if (-not (Test-Path -LiteralPath $HostSenderScript)) {
    throw "Host production sender script not found: $HostSenderScript"
}
if (-not (Test-Path -LiteralPath $CredentialPath)) {
    throw "Protected credential file not found: $CredentialPath"
}
if (-not (Test-Path -LiteralPath $FidPath)) {
    throw "Firebase Messaging FID secret not found: $FidPath"
}

$adb = Resolve-Adb
Assert-OneAuthorizedDevice $adb

$listenerPath = Resolve-ListenerEvidencePath
$listenerRecords = Read-JsonLines $listenerPath

$launch = $listenerRecords |
    Where-Object {
        $_.operation -eq 'harness_launch' -and
        $_.outcome -eq 'success'
    } |
    Select-Object -Last 1

if (-not $launch) {
    throw 'Notification listener evidence has no successful harness_launch record.'
}

$packageForm = [string]$launch.data.PackageForm
if ($packageForm -ne 'packaged') {
    throw "Notification mirroring tracer requires the packaged listener path; observed package form '$packageForm'."
}

$subscription = $listenerRecords |
    Where-Object {
        $_.operation -eq 'NotificationChanged.subscribe' -and
        $_.outcome -eq 'success'
    } |
    Select-Object -Last 1

if (-not $subscription) {
    throw 'Notification event listener is not proven subscribed in the current evidence file. Start Events in the packaged harness first.'
}

$startIndex = $listenerRecords.Count
$startedUtc = [DateTimeOffset]::UtcNow
$deadline = $startedUtc.AddSeconds($TimeoutSeconds)

Write-Host "Notification mirroring tracer started: $($startedUtc.ToString('o'))"
Write-Host "Listener evidence: $listenerPath"
Write-Host 'Waiting for a NEW synthetic Windows notification observed by the packaged listener...'

$windowsRecord = $null

while ([DateTimeOffset]::UtcNow -lt $deadline -and -not $windowsRecord) {
    Start-Sleep -Milliseconds 250
    $current = Read-JsonLines $listenerPath

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
    throw "Timed out after $TimeoutSeconds seconds waiting for a synthetic notification event snapshot."
}

$title = [string]$windowsRecord.data.title
$markerMatch = [regex]::Match($title, '^DOKI-NOTIFICATION-(\d{13})-([0-9a-fA-F]+)')
if (-not $markerMatch.Success) {
    throw "Synthetic title does not contain the expected timestamped marker: $title"
}

$sourceEpochMs = [Int64]$markerMatch.Groups[1].Value
$sourceSuffix = $markerMatch.Groups[2].Value.ToLowerInvariant()
$sourceCreatedUtc = [DateTimeOffset]::FromUnixTimeMilliseconds($sourceEpochMs)
$listenerObservedUtc = [DateTimeOffset]::Parse([string]$windowsRecord.timestampUtc)
$testId = "DOKI-NOTIFICATION-MIRROR-$sourceEpochMs-$sourceSuffix"

Write-Host "Windows source marker: $($markerMatch.Value)"
Write-Host "Listener observed: $($listenerObservedUtc.ToString('o'))"
Write-Host "Sending test ID via production FCM sender: $testId"

$sendOutput = @(
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HostSenderScript `
        -CredentialPath $CredentialPath `
        -FidPath $FidPath `
        -TestId $testId 2>&1
)
if ($LASTEXITCODE -ne 0) {
    $errText = $sendOutput -join "`n"
    throw "Production FCM sender failed with exit code ${LASTEXITCODE}: $errText"
}

$sendOk = @($sendOutput | Where-Object { [string]$_ -like 'SEND_OK *' })
if ($sendOk.Count -ne 1) {
    $outText = $sendOutput -join "`n"
    throw "Production FCM sender did not report SEND_OK: $outText"
}

$sendOkLine = [string]$sendOk[0]
$parsedProjectId = $null
if ($sendOkLine -match '\bproject_id=(\S+)') {
    $parsedProjectId = $Matches[1]
}
if ([string]::IsNullOrWhiteSpace($parsedProjectId)) {
    throw "Could not parse project_id from SEND_OK record: $sendOkLine"
}
if ($parsedProjectId -ne $ProjectId) {
    throw "Project ID mismatch: parameter was '$ProjectId' but FCM sender reported '$parsedProjectId'."
}

$senderCompletedUtc = [DateTimeOffset]::UtcNow
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
    throw "Android callback was not observed for test ID $testId"
}
if (-not $notification) {
    throw "Android local notification was not observed for test ID $testId"
}

$callbackUtc = [DateTimeOffset]::Parse([string]$callback.timestampUtc)
$notificationUtc = [DateTimeOffset]::Parse([string]$notification.timestampUtc)

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$outputPath = Join-Path $EvidenceRoot ("notification-mirroring-{0}.json" -f ($testId -replace '[^A-Za-z0-9_.-]', '_'))

$result = [ordered]@{
    phase = 'notification_mirroring'
    result = 'PASS'
    testId = $testId
    projectId = $ProjectId
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
        accepted = $true
        implementation = 'production_fcm_sender'
        senderOutput = [string]$sendOk[0]
        senderCompletedUtc = $senderCompletedUtc.ToString('o')
    }
    android = [ordered]@{
        callbackUtc = $callbackUtc.ToString('o')
        foreground = [bool]$callback.data.foreground
        localNotificationUtc = $notificationUtc.ToString('o')
        localNotificationStatus = [string]$notification.data.status
    }
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputPath -Encoding utf8

Write-Host 'Notification mirroring E2E PASS'
Write-Host "Evidence: $outputPath"
Write-Host "Windows source created: $($sourceCreatedUtc.ToString('o'))"
Write-Host "Listener observed:      $($listenerObservedUtc.ToString('o'))"
Write-Host "Sender completed:       $($senderCompletedUtc.ToString('o'))"
Write-Host "Android callback:       $($callbackUtc.ToString('o'))"
Write-Host "Local notification:     $($notificationUtc.ToString('o'))"
