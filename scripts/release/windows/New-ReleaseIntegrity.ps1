[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$OutputDirectory,
    [string]$SourceCommit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $PSScriptRoot 'CertificateMarkers.ps1')

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path $RepoRoot 'artifacts\windows\package\Doki-Dango-x64.msix'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepoRoot 'artifacts\windows\release-integrity'
}
if ([string]::IsNullOrWhiteSpace($SourceCommit)) {
    $SourceCommit = (& git -C $RepoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse HEAD failed with exit code $LASTEXITCODE"
    }
}
if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'SourceCommit must be a full 40-character commit SHA.'
}

$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

Add-Type -AssemblyName System.IO.Compression.FileSystem

$archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    $entry = $archive.GetEntry('AppxManifest.xml')
    if (-not $entry) {
        throw 'MSIX does not contain AppxManifest.xml.'
    }

    $stream = $entry.Open()
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        [xml]$manifest = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
} finally {
    $archive.Dispose()
}

$ns = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
$ns.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
$identity = $manifest.SelectSingleNode('/f:Package/f:Identity', $ns)
if (-not $identity) {
    throw 'MSIX manifest is missing Package/Identity.'
}

if ($identity.Name -ne 'ItzHerzchen.DokiDango') {
    throw "Unexpected package name: $($identity.Name)"
}
if ($identity.Publisher -ne 'CN=ItzHerzchen') {
    throw "Unexpected package publisher: $($identity.Publisher)"
}
if ($identity.ProcessorArchitecture -ne 'x64') {
    throw "Unexpected package architecture: $($identity.ProcessorArchitecture)"
}

$packageItem = Get-Item -LiteralPath $PackagePath
$hash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToUpperInvariant()
$signature = Get-AuthenticodeSignature -LiteralPath $PackagePath
$certificate = $signature.SignerCertificate

$signatureFacts = [ordered]@{
    status = $signature.Status.ToString()
    signerSubject = if ($certificate) { $certificate.Subject } else { $null }
    signerIssuer = if ($certificate) { $certificate.Issuer } else { $null }
    signerThumbprint = if ($certificate) { $certificate.Thumbprint } else { $null }
    signerFriendlyName = if ($certificate) { $certificate.FriendlyName } else { $null }
    developmentSigner = if ($certificate) {
        Test-DokiDangoDevelopmentSignerCertificate -Certificate $certificate
    } else {
        $false
    }
    selfSigned = if ($certificate) {
        $certificate.Subject -eq $certificate.Issuer
    } else {
        $false
    }
}

$record = [ordered]@{
    schemaVersion = 1
    sourceCommit = $SourceCommit.ToLowerInvariant()
    artifact = [ordered]@{
        fileName = $packageItem.Name
        sizeBytes = [int64]$packageItem.Length
        sha256 = $hash
    }
    packageIdentity = [ordered]@{
        name = [string]$identity.Name
        publisher = [string]$identity.Publisher
        version = [string]$identity.Version
        architecture = [string]$identity.ProcessorArchitecture
    }
    signature = $signatureFacts
}

$utf8NoBom = New-Object Text.UTF8Encoding($false)
$manifestPath = Join-Path $OutputDirectory 'release-integrity.json'
$shaPath = Join-Path $OutputDirectory 'SHA256SUMS'

[IO.File]::WriteAllText($manifestPath, ($record | ConvertTo-Json -Depth 8), $utf8NoBom)
[IO.File]::WriteAllText(
    $shaPath,
    ("{0} *{1}{2}" -f $hash, $packageItem.Name, [Environment]::NewLine),
    $utf8NoBom
)

Write-Host "Release integrity manifest: $manifestPath"
Write-Host "SHA256 manifest: $shaPath"
Write-Host "Package SHA256: $hash"
Write-Host "Authenticode status: $($signature.Status)"
