[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$IntegrityManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$SbomPath,

    [Parameter(Mandatory = $true)]
    [string]$SourceCommit,

    [Parameter(Mandatory = $true)]
    [string]$TrustedSignerThumbprint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'CertificateMarkers.ps1')

if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'SourceCommit must be a full 40-character commit SHA.'
}

$trustedThumbprint = ($TrustedSignerThumbprint -replace '\s', '').ToUpperInvariant()
if ($trustedThumbprint -notmatch '^[0-9A-F]{40}$') {
    throw 'TrustedSignerThumbprint must be a 40-character SHA-1 certificate thumbprint.'
}

$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
$IntegrityManifestPath = (Resolve-Path -LiteralPath $IntegrityManifestPath).Path
$SbomPath = (Resolve-Path -LiteralPath $SbomPath).Path

$integrity = Get-Content -LiteralPath $IntegrityManifestPath -Raw | ConvertFrom-Json
$sbom = Get-Content -LiteralPath $SbomPath -Raw | ConvertFrom-Json

if ([int]$integrity.schemaVersion -ne 1) {
    throw "Unsupported release integrity schema: $($integrity.schemaVersion)"
}
if ([string]$integrity.sourceCommit -ne $SourceCommit.ToLowerInvariant()) {
    throw 'Release integrity source commit does not match the requested candidate.'
}

$packageItem = Get-Item -LiteralPath $PackagePath
$actualHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToUpperInvariant()

if ([string]$integrity.artifact.fileName -ne $packageItem.Name) {
    throw 'Release integrity artifact file name does not match the package.'
}
if ([int64]$integrity.artifact.sizeBytes -ne [int64]$packageItem.Length) {
    throw 'Release integrity artifact size does not match the package.'
}
if ([string]$integrity.artifact.sha256 -ne $actualHash) {
    throw 'Release integrity SHA256 does not match the package.'
}
if ([string]$integrity.packageIdentity.name -ne 'ItzHerzchen.DokiDango') {
    throw 'Release integrity contains an unexpected package name.'
}
if ([string]$integrity.packageIdentity.publisher -ne 'CN=ItzHerzchen') {
    throw 'Release integrity contains an unexpected publisher.'
}
if ([string]$integrity.packageIdentity.architecture -ne 'x64') {
    throw 'Release integrity contains an unexpected architecture.'
}

if ([string]$sbom.spdxVersion -ne 'SPDX-2.3') {
    throw "Unexpected SPDX version: $($sbom.spdxVersion)"
}
$expectedNamespace = "https://github.com/Herzchens/Doki-Dango/spdx/$($SourceCommit.ToLowerInvariant())"
if ([string]$sbom.documentNamespace -ne $expectedNamespace) {
    throw 'SBOM source commit namespace does not match the requested candidate.'
}
if (@($sbom.packages).Count -lt 3) {
    throw 'SBOM does not contain the expected package inventory.'
}
if (@($sbom.documentDescribes).Count -lt 3) {
    throw 'SBOM does not describe the complete Doki-Dango Rust workspace.'
}

$signature = Get-AuthenticodeSignature -LiteralPath $PackagePath
$certificate = $signature.SignerCertificate

if ($signature.Status -ne 'Valid') {
    throw "Release package Authenticode signature is not valid: $($signature.Status)"
}
if (-not $certificate) {
    throw 'Release package did not expose a signer certificate.'
}
if ($certificate.Subject -ne 'CN=ItzHerzchen') {
    throw "Unexpected release signer subject: $($certificate.Subject)"
}
if (Test-DokiDangoDevelopmentSignerCertificate -Certificate $certificate) {
    throw 'Development signing certificate is forbidden for release publication.'
}
 if ($certificate.NotBefore -gt (Get-Date) -or $certificate.NotAfter -le (Get-Date)) {
    throw 'Release signer certificate is outside its current validity period.'
}
if ($certificate.Thumbprint.ToUpperInvariant() -ne $trustedThumbprint) {
    throw 'Release signer thumbprint does not match the approved trusted signer.'
}

if ([string]$integrity.signature.status -ne 'Valid') {
    throw 'Release integrity was not generated from a validly signed package.'
}
if ([string]$integrity.signature.signerThumbprint -ne $certificate.Thumbprint) {
    throw 'Release integrity signer thumbprint does not match the package.'
}
if ([bool]$integrity.signature.developmentSigner) {
    throw 'Release integrity identifies the package as development-signed.'
}
 Write-Host 'Release candidate trust gate: PASS'
Write-Host "Package: $($packageItem.Name)"
Write-Host "SHA256: $actualHash"
Write-Host "Signer: $($certificate.Subject)"
Write-Host "Source commit: $($SourceCommit.ToLowerInvariant())"
