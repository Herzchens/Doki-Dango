[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'arm64')]
    [string]$Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window. Trusting the local test certificate requires administrator rights.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$PackageDir = Join-Path $RepoRoot 'artifacts\a1\package'
$MsixPath = Join-Path $PackageDir "DokiDango.A1Harness-$Architecture.msix"
$CerPath = Join-Path $PackageDir 'DokiDango.A1Test.cer'

if (-not (Test-Path $MsixPath)) {
    throw "MSIX not found: $MsixPath"
}

if (-not (Test-Path $CerPath)) {
    throw "Certificate not found: $CerPath"
}

$trusted = Import-Certificate `
    -FilePath $CerPath `
    -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'

Write-Host "Trusted test certificate: $($trusted.Thumbprint)"

$signature = Get-AuthenticodeSignature -FilePath $MsixPath
Write-Host "Signature status: $($signature.Status)"
Write-Host "Signer subject: $($signature.SignerCertificate.Subject)"

Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown

Get-AppxPackage -Name 'Herzchens.DokiDango.A1Harness' |
    Select-Object Name, PackageFullName, Version, Architecture, InstallLocation
