[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,
    [string]$FidPath = (Join-Path $env:LOCALAPPDATA 'Doki-Dango\B\secrets\fid.txt'),
    [string]$AccessTokenPath = (Join-Path $env:LOCALAPPDATA 'Doki-Dango\B\secrets\access-token.json'),
    [string]$TestId,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Net.Http

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$EvidenceRoot = Join-Path $RepoRoot 'artifacts\android\firebase-messaging\evidence'
$PackageName = 'dev.dokidango.bharness'

if (-not (Test-Path -LiteralPath $FidPath)) {
    throw "FID secret file not found: $FidPath"
}
if (-not (Test-Path -LiteralPath $AccessTokenPath)) {
    throw "OAuth access-token file not found: $AccessTokenPath"
}

$fid = (Get-Content -LiteralPath $FidPath -Raw).Trim()
$tokenRecord = Get-Content -LiteralPath $AccessTokenPath -Raw | ConvertFrom-Json
$token = [string]$tokenRecord.access_token
if ([string]::IsNullOrWhiteSpace($fid) -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'FID or OAuth access token is empty.'
}

if ([string]::IsNullOrWhiteSpace($TestId)) {
    $TestId = 'DOKI-B-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
}
if (-not $TestId.StartsWith('DOKI-B-', [StringComparison]::Ordinal)) {
    throw 'TestId must start with DOKI-B-.'
}

$payload = [ordered]@{
    validate_only = [bool]$ValidateOnly
    message = [ordered]@{
        fid = $fid
        data = [ordered]@{
            doki_test_id = $TestId
            doki_kind = 'synthetic'
        }
        android = [ordered]@{
            priority = 'HIGH'
            ttl = '60s'
            restricted_package_name = $PackageName
        }
    }
}
$json = $payload | ConvertTo-Json -Depth 8 -Compress
$uri = "https://fcm.googleapis.com/v1/projects/$ProjectId/messages:send"
$started = [DateTimeOffset]::UtcNow

$client = [Net.Http.HttpClient]::new()
try {
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
    $response = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
    $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
}
finally {
    $client.Dispose()
}

$finished = [DateTimeOffset]::UtcNow
$sanitizedBody = $responseBody.Replace($fid, '<redacted-fid>').Replace($token, '<redacted-token>')
if ($sanitizedBody.Length -gt 4000) {
    $sanitizedBody = $sanitizedBody.Substring(0, 4000)
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$evidencePath = Join-Path $EvidenceRoot ("send-{0}.json" -f ($TestId -replace '[^A-Za-z0-9_.-]', '_'))
$record = [ordered]@{
    timestampUtc = $finished.ToString('o')
    testId = $TestId
    projectId = $ProjectId
    validateOnly = [bool]$ValidateOnly
    httpStatus = [int]$response.StatusCode
    accepted = $response.IsSuccessStatusCode
    elapsedMs = ($finished - $started).TotalMilliseconds
    response = $sanitizedBody
}
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $evidencePath -Encoding utf8

Write-Host "Test ID: $TestId"
Write-Host "HTTP status: $([int]$response.StatusCode)"
Write-Host "Accepted: $($response.IsSuccessStatusCode)"
Write-Host "Send evidence: $evidencePath"

if (-not $response.IsSuccessStatusCode) {
    throw "FCM HTTP v1 send failed with status $([int]$response.StatusCode)."
}
