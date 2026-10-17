[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Get-AppxPackage -Name 'Herzchens.DokiDango.NotificationListenerDotNet' |
    Remove-AppxPackage -ErrorAction SilentlyContinue

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())

if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Get-ChildItem 'Cert:\LocalMachine\TrustedPeople' |
        Where-Object { $_.Subject -eq 'CN=Doki-Dango Notification Listener DotNet Test' } |
        Remove-Item -Force

    Write-Host 'Removed notification listener package and trusted test certificate.'
}
else {
    Write-Host 'Removed notification listener package. Re-run elevated to remove the trusted test certificate.'
}
