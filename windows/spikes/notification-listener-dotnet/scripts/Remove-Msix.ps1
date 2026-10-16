[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Get-AppxPackage -Name 'Herzchens.DokiDango.A1Harness' |
    Remove-AppxPackage -ErrorAction SilentlyContinue

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())

if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Get-ChildItem 'Cert:\LocalMachine\TrustedPeople' |
        Where-Object { $_.Subject -eq 'CN=Doki-Dango A1 Test' } |
        Remove-Item -Force

    Write-Host 'Removed A1 package and trusted test certificate.'
}
else {
    Write-Host 'Removed A1 package. Re-run elevated to remove the trusted test certificate.'
}
