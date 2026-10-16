[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window. Trusting the local test certificate requires administrator rights.'
}

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$PackageDir = Join-Path $RepoRoot 'artifacts\windows\notification-listener-rust\package'
$MsixPath = Join-Path $PackageDir 'DokiDango.A21RustHarness-x64.msix'
$CerPath = Join-Path $PackageDir 'DokiDango.A21Test.cer'

if (-not (Test-Path -LiteralPath $MsixPath)) {
    throw "MSIX not found: $MsixPath"
}
if (-not (Test-Path -LiteralPath $CerPath)) {
    throw "Certificate not found: $CerPath"
}

$trusted = Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
Write-Host "Trusted test certificate: $($trusted.Thumbprint)"

$signature = Get-AuthenticodeSignature -FilePath $MsixPath
Write-Host "Signature status: $($signature.Status)"
Write-Host "Signer subject: $($signature.SignerCertificate.Subject)"

Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown

Get-AppxPackage -Name 'Herzchens.DokiDango.A21RustHarness' |
    Select-Object Name, PackageFullName, Version, Architecture, InstallLocation
