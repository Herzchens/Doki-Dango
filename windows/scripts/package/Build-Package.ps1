[CmdletBinding()]
param(
    [string]$PackageVersion,
    [string]$OutputPath,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$Manifest = Join-Path $RepoRoot 'windows\packaging\AppxManifest.xml'
$Assets = Join-Path $RepoRoot 'windows\packaging\Assets'
$ArtifactsRoot = Join-Path $RepoRoot 'artifacts\windows'
$StageDir = Join-Path $ArtifactsRoot 'msix-stage-x64'
$DefaultPackageDir = Join-Path $ArtifactsRoot 'package'
$HostExePath = Join-Path $RepoRoot 'target\release\dokidango.exe'
$UiExePath = Join-Path $RepoRoot 'target\release\dokidango-ui.exe'

function ConvertTo-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }

    return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Assert-PackageVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw 'PackageVersion must contain exactly four numeric components.'
    }

    foreach ($component in @($Version.Split('.'))) {
        $value = [int]$component
        if ($value -lt 0 -or $value -gt 65535) {
            throw "PackageVersion component is outside 0..65535: $component"
        }
    }
}

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

if (-not [string]::IsNullOrWhiteSpace($PackageVersion)) {
    Assert-PackageVersion -Version $PackageVersion
}

$MsixPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $DefaultPackageDir 'Doki-Dango-x64.msix'
} else {
    ConvertTo-AbsolutePath -Path $OutputPath -BasePath $RepoRoot
}
$PackageDir = Split-Path -Parent $MsixPath
if ([string]::IsNullOrWhiteSpace($PackageDir)) {
    throw 'OutputPath must include a package file name.'
}

$makeAppx = Find-WindowsSdkTool -Name 'makeappx.exe'

if (-not $SkipBuild) {
    & cargo build --locked --release -p doki-dango-host -p doki-dango-ui
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
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

if (-not [string]::IsNullOrWhiteSpace($PackageVersion)) {
    $stageManifestPath = Join-Path $StageDir 'AppxManifest.xml'
    [xml]$stageManifest = Get-Content -LiteralPath $stageManifestPath -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($stageManifest.NameTable)
    $ns.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
    $identity = $stageManifest.SelectSingleNode('/f:Package/f:Identity', $ns)
    if (-not $identity) {
        throw 'Staged package manifest is missing Package/Identity.'
    }

    $identity.Version = $PackageVersion

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object Text.UTF8Encoding($false)
    $settings.Indent = $true
    $writer = [Xml.XmlWriter]::Create($stageManifestPath, $settings)
    try {
        $stageManifest.Save($writer)
    } finally {
        $writer.Dispose()
    }
}

& $makeAppx pack /d $StageDir /p $MsixPath /o
if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx failed with exit code $LASTEXITCODE"
}

$hash = Get-FileHash -LiteralPath $MsixPath -Algorithm SHA256

Write-Host "Unsigned MSIX: $MsixPath"
if (-not [string]::IsNullOrWhiteSpace($PackageVersion)) {
    Write-Host "Package version: $PackageVersion"
}
Write-Host "SHA256: $($hash.Hash)"
