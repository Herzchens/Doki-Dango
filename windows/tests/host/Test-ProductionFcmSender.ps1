[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CredentialPath,

    [string]$FidPath = (Join-Path $env:LOCALAPPDATA 'Doki-Dango\B\secrets\fid.txt'),

    [string]$TestId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$HarnessExe = Join-Path $RepoRoot 'target\release\examples\production_fcm_sender.exe'

if (-not (Test-Path -LiteralPath $CredentialPath)) {
    throw "Protected credential file not found: $CredentialPath"
}
if (-not (Test-Path -LiteralPath $FidPath)) {
    throw "FID file not found: $FidPath"
}

if ([string]::IsNullOrWhiteSpace($TestId)) {
    $TestId = 'DOKI-B-PROD-{0}-{1}' -f (
        [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    ), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
}
if (-not $TestId.StartsWith('DOKI-B-PROD-', [StringComparison]::Ordinal)) {
    throw 'TestId must start with DOKI-B-PROD-.'
}

$sentAt = [DateTimeOffset]::UtcNow
$expiresAt = $sentAt.AddMinutes(1)

& cargo build --locked --release -p doki-dango-host --example production_fcm_sender
if ($LASTEXITCODE -ne 0) {
    throw "Production sender harness build failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $HarnessExe)) {
    throw "Production sender harness executable not found: $HarnessExe"
}

$output = @(
    & $HarnessExe $CredentialPath $FidPath $TestId ($sentAt.ToString('o')) ($expiresAt.ToString('o')) 2>&1
)
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    throw "Production FCM sender failed with exit code $exitCode."
}

$success = @($output | Where-Object { [string]$_ -like 'SEND_OK *' })
if ($success.Count -ne 1) {
    throw 'Production sender did not emit exactly one sanitized SEND_OK record.'
}

Write-Host "Test ID: $TestId"
Write-Host ([string]$success[0])
Write-Host 'Production Rust FCM sender: PASS'
