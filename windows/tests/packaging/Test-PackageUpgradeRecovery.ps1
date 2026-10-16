[CmdletBinding()]
param(
    [switch]$ConfirmPackageRegistrationTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $ConfirmPackageRegistrationTest) {
    throw 'This test changes the registered Doki-Dango package version. Re-run with -ConfirmPackageRegistrationTest.'
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this test from an elevated PowerShell window.'
}

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$BuildScript = Join-Path $RepoRoot 'windows\scripts\package\Build-Package.ps1'
$SignScript = Join-Path $RepoRoot 'windows\scripts\package\Sign-DevelopmentPackage.ps1'
$PackageName = 'ItzHerzchen.DokiDango'
$VersionA = [version]'0.1.65000.0'
$VersionB = [version]'0.1.65001.0'
$TempRoot = Join-Path $env:TEMP ("Doki-Dango-UpgradeRecovery-" + [Guid]::NewGuid().ToString('N'))
$PackageA = Join-Path $TempRoot 'Doki-Dango-A.msix'
$PackageB = Join-Path $TempRoot 'Doki-Dango-B.msix'
$RestorePackage = Join-Path $TempRoot 'Doki-Dango-Restore.msix'
$CertificatePath = Join-Path $TempRoot 'Doki-Dango-Development.cer'
$StateDir = Join-Path $env:LOCALAPPDATA 'Doki-Dango\Host'
$StateMarker = Join-Path $StateDir ("qa-upgrade-recovery-" + [Guid]::NewGuid().ToString('N') + '.txt')
$StateValue = [Guid]::NewGuid().ToString('N')

$originalPackage = Get-AppxPackage -Name $PackageName | Select-Object -First 1
$originalVersion = if ($originalPackage) { [version]$originalPackage.Version } else { $null }

if ($originalVersion -and $originalVersion -ge $VersionA) {
    throw "Installed package version $originalVersion is too high for the reserved QA versions $VersionA/$VersionB."
}

New-Item -ItemType Directory -Force -Path $TempRoot, $StateDir | Out-Null
[IO.File]::WriteAllText($StateMarker, $StateValue, (New-Object Text.UTF8Encoding($false)))

function Assert-StateMarker {
    if (-not (Test-Path -LiteralPath $StateMarker)) {
        throw 'Synthetic Host state marker disappeared during package transition.'
    }

    $value = [IO.File]::ReadAllText($StateMarker)
    if ($value -ne $StateValue) {
        throw 'Synthetic Host state marker changed during package transition.'
    }
}

function Assert-InstalledVersion {
    param([Parameter(Mandatory = $true)][version]$Expected)

    $package = Get-AppxPackage -Name $PackageName | Select-Object -First 1
    if (-not $package) {
        throw "Doki-Dango package is not installed; expected version $Expected."
    }
    if ([version]$package.Version -ne $Expected) {
        throw "Installed version mismatch. Expected $Expected, found $($package.Version)."
    }

    return $package
}

$testError = $null
$recoveryError = $null

try {
    & $BuildScript -PackageVersion $VersionA.ToString() -OutputPath $PackageA
    & $BuildScript -PackageVersion $VersionB.ToString() -OutputPath $PackageB -SkipBuild

    if ($originalPackage) {
        & $BuildScript -PackageVersion $originalVersion.ToString() -OutputPath $RestorePackage -SkipBuild
    }

    & $SignScript -PackagePath $PackageA -CertificatePath $CertificatePath
    & $SignScript -PackagePath $PackageB -CertificatePath $CertificatePath
    if ($originalPackage) {
        & $SignScript -PackagePath $RestorePackage -CertificatePath $CertificatePath
    }

    $trusted = Import-Certificate -FilePath $CertificatePath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
    if (-not $trusted) {
        throw 'Failed to trust the development certificate for package registration.'
    }

    Stop-Process -Name 'dokidango', 'dokidango-ui' -Force -ErrorAction SilentlyContinue

    Add-AppxPackage -Path $PackageA -ForceApplicationShutdown
    $installedA = Assert-InstalledVersion -Expected $VersionA
    Assert-StateMarker
    $familyName = $installedA.PackageFamilyName

    Add-AppxPackage -Path $PackageB -ForceApplicationShutdown
    $installedB = Assert-InstalledVersion -Expected $VersionB
    Assert-StateMarker
    if ($installedB.PackageFamilyName -ne $familyName) {
        throw 'Package family changed across forward upgrade.'
    }

    Add-AppxPackage -Path $PackageA -ForceApplicationShutdown -ForceUpdateFromAnyVersion
    $rolledBack = Assert-InstalledVersion -Expected $VersionA
    Assert-StateMarker
    if ($rolledBack.PackageFamilyName -ne $familyName) {
        throw 'Package family changed across rollback.'
    }

    Write-Host 'Forward package upgrade: PASS'
    Write-Host 'Forced package rollback: PASS'
    Write-Host 'Package family continuity: PASS'
    Write-Host 'External Host state preservation: PASS'
} catch {
    $testError = $_
}

try {
    Stop-Process -Name 'dokidango', 'dokidango-ui' -Force -ErrorAction SilentlyContinue

    if ($originalPackage) {
        Add-AppxPackage -Path $RestorePackage -ForceApplicationShutdown -ForceUpdateFromAnyVersion
        $restored = Assert-InstalledVersion -Expected $originalVersion
        if ($restored.PackageFamilyName -ne $originalPackage.PackageFamilyName) {
            throw 'Restored package family does not match the original package family.'
        }
        Write-Host "Original package version restored: $originalVersion"
    } else {
        $current = Get-AppxPackage -Name $PackageName | Select-Object -First 1
        if ($current) {
            Remove-AppxPackage -Package $current.PackageFullName
        }
        if (Get-AppxPackage -Name $PackageName) {
            throw 'Doki-Dango package remained registered after cleanup.'
        }
        Write-Host 'No original package existed; QA package registration removed.'
    }
} catch {
    $recoveryError = $_
}

Remove-Item -LiteralPath $StateMarker -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($recoveryError) {
    $testMessage = if ($testError) { $testError.Exception.Message } else { 'none' }
    throw "Package recovery failed: $($recoveryError.Exception.Message). Original test error: $testMessage"
}
if ($testError) {
    throw $testError
}

Write-Host 'Package upgrade/rollback/recovery runtime gate: PASS'
