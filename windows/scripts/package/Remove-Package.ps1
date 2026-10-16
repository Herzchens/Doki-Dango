[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$packages = @(Get-AppxPackage -Name 'ItzHerzchen.DokiDango')
foreach ($package in $packages) {
    Remove-AppxPackage -Package $package.PackageFullName
}

Write-Host "Removed $($packages.Count) Doki-Dango package(s)."
