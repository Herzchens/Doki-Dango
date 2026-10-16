[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window. Trusting the development certificate requires administrator rights.'
}

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$PackageDir = Join-Path $RepoRoot 'artifacts\windows\package'
$MsixPath = Join-Path $PackageDir 'Doki-Dango-x64.msix'
$CerPath = Join-Path $PackageDir 'Doki-Dango-Development.cer'
$Publisher = 'CN=ItzHerzchen'

if (-not (Test-Path -LiteralPath $MsixPath)) {
    throw "MSIX not found: $MsixPath"
}
if (-not (Test-Path -LiteralPath $CerPath)) {
    throw "Development certificate not found: $CerPath"
}

$signature = Get-AuthenticodeSignature -FilePath $MsixPath
if ($signature.Status -ne 'Valid') {
    throw "Package signature is not valid: $($signature.Status)"
}
if ($signature.SignerCertificate.Subject -ne $Publisher) {
    throw "Unexpected package signer: $($signature.SignerCertificate.Subject)"
}

$trusted = Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
Write-Host "Trusted development certificate: $($trusted.Thumbprint)"

Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown

$package = Get-AppxPackage -Name 'ItzHerzchen.DokiDango'
if (-not $package) {
    throw 'Installed Doki-Dango package was not found after Add-AppxPackage.'
}

$package | Select-Object Name, PackageFullName, Version, Architecture, InstallLocation
