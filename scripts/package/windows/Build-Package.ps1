[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Manifest = Join-Path $RepoRoot 'packaging\windows\AppxManifest.xml'
$Assets = Join-Path $RepoRoot 'packaging\windows\Assets'
$ArtifactsRoot = Join-Path $RepoRoot 'artifacts\windows'
$StageDir = Join-Path $ArtifactsRoot 'msix-stage-x64'
$PackageDir = Join-Path $ArtifactsRoot 'package'
$MsixPath = Join-Path $PackageDir 'Doki-Dango-x64.msix'
$HostExePath = Join-Path $RepoRoot 'target\release\dokidango.exe'
$UiExePath = Join-Path $RepoRoot 'target\release\dokidango-ui.exe'

function Get-WindowsSdkBinRoots {
    $roots = @()

    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    )) {
        $installedRoots = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($installedRoots -and $installedRoots.KitsRoot10) {
            $roots += (Join-Path $installedRoots.KitsRoot10 'bin')
        }
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($programFilesX86) {
        $roots += (Join-Path $programFilesX86 'Windows Kits\10\bin')
    }

    return @(
        $roots |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
            ForEach-Object { (Resolve-Path -LiteralPath $_).Path } |
            Select-Object -Unique
    )
}

function Find-WindowsSdkTool {
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($kitsRoot in @(Get-WindowsSdkBinRoots)) {
        $versionDirectories = @(
            Get-ChildItem -LiteralPath $kitsRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
        )

        foreach ($directory in $versionDirectories) {
            $candidate = Join-Path $directory.FullName "x64\$Name"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }

        $direct = Join-Path $kitsRoot "x64\$Name"
        if (Test-Path -LiteralPath $direct) {
            return $direct
        }
    }

    throw "$Name not found in Windows SDK."
}

$makeAppx = Find-WindowsSdkTool -Name 'makeappx.exe'

& cargo build --locked --release -p doki-dango-host -p doki-dango-ui
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $HostExePath)) {
    throw "Host executable not found: $HostExePath"
}

if (-not (Test-Path -LiteralPath $UiExePath)) {
    throw "UI executable not found: $UiExePath"
}

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $StageDir
New-Item -ItemType Directory -Force -Path $StageDir, $PackageDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $MsixPath

Copy-Item -LiteralPath $HostExePath -Destination (Join-Path $StageDir 'dokidango.exe')
Copy-Item -LiteralPath $UiExePath -Destination (Join-Path $StageDir 'dokidango-ui.exe')
Copy-Item -LiteralPath $Manifest -Destination (Join-Path $StageDir 'AppxManifest.xml')
Copy-Item -LiteralPath $Assets -Destination (Join-Path $StageDir 'Assets') -Recurse -Force

& $makeAppx pack /d $StageDir /p $MsixPath /o
if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx failed with exit code $LASTEXITCODE"
}

$hash = Get-FileHash -LiteralPath $MsixPath -Algorithm SHA256

Write-Host "Unsigned MSIX: $MsixPath"
Write-Host "SHA256: $($hash.Hash)"
