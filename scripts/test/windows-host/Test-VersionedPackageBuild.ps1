[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$BuildScript = Join-Path $RepoRoot 'scripts\package\windows\Build-Package.ps1'
$SourceManifest = Join-Path $RepoRoot 'packaging\windows\AppxManifest.xml'
$TempRoot = Join-Path $env:TEMP ("Doki-Dango-VersionedPackage-" + [Guid]::NewGuid().ToString('N'))
$VersionA = '0.1.100.0'
$VersionB = '0.1.101.0'
$PackageA = Join-Path $TempRoot 'Doki-Dango-A.msix'
$PackageB = Join-Path $TempRoot 'Doki-Dango-B.msix'

function Get-MsixIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if (-not $entry) {
            throw "MSIX is missing AppxManifest.xml: $Path"
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
        throw "MSIX manifest is missing Package/Identity: $Path"
    }

    return [pscustomobject]@{
        Name = [string]$identity.Name
        Publisher = [string]$identity.Publisher
        Version = [string]$identity.Version
        Architecture = [string]$identity.ProcessorArchitecture
    }
}

$sourceHashBefore = (Get-FileHash -LiteralPath $SourceManifest -Algorithm SHA256).Hash

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
try {
    & $BuildScript -PackageVersion $VersionA -OutputPath $PackageA -SkipBuild
    & $BuildScript -PackageVersion $VersionB -OutputPath $PackageB -SkipBuild

    $identityA = Get-MsixIdentity -Path $PackageA
    $identityB = Get-MsixIdentity -Path $PackageB

    foreach ($identity in @($identityA, $identityB)) {
        if ($identity.Name -ne 'ItzHerzchen.DokiDango') {
            throw "Unexpected package name: $($identity.Name)"
        }
        if ($identity.Publisher -ne 'CN=ItzHerzchen') {
            throw "Unexpected publisher: $($identity.Publisher)"
        }
        if ($identity.Architecture -ne 'x64') {
            throw "Unexpected architecture: $($identity.Architecture)"
        }
    }

    if ($identityA.Version -ne $VersionA) {
        throw "Version A mismatch: $($identityA.Version)"
    }
    if ($identityB.Version -ne $VersionB) {
        throw "Version B mismatch: $($identityB.Version)"
    }

    $hashA = (Get-FileHash -LiteralPath $PackageA -Algorithm SHA256).Hash
    $hashB = (Get-FileHash -LiteralPath $PackageB -Algorithm SHA256).Hash
    if ($hashA -eq $hashB) {
        throw 'Versioned package artifacts unexpectedly have identical SHA256 hashes.'
    }

    $sourceHashAfter = (Get-FileHash -LiteralPath $SourceManifest -Algorithm SHA256).Hash
    if ($sourceHashAfter -ne $sourceHashBefore) {
        throw 'Versioned package build mutated the tracked AppxManifest.xml.'
    }

    Write-Host 'Versioned package identity continuity: PASS'
    Write-Host "Package A version: $VersionA"
    Write-Host "Package B version: $VersionB"
    Write-Host 'Tracked package manifest unchanged: PASS'
} finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
