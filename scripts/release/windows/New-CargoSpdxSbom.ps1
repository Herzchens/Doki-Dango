[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$SourceCommit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $RepoRoot 'artifacts\windows\release-integrity\doki-dango.spdx.json'
}
if ([string]::IsNullOrWhiteSpace($SourceCommit)) {
    $SourceCommit = (& git -C $RepoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse HEAD failed with exit code $LASTEXITCODE"
    }
}
if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'SourceCommit must be a full 40-character commit SHA.'
}

$metadataText = (& cargo metadata --locked --format-version 1 --manifest-path (Join-Path $RepoRoot 'Cargo.toml') | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "cargo metadata failed with exit code $LASTEXITCODE"
}
$metadata = $metadataText | ConvertFrom-Json

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$idToSpdx = @{}
$packages = @()
$index = 0

foreach ($package in @($metadata.packages | Sort-Object name, version, id)) {
    $index += 1
    $spdxId = "SPDXRef-Package-$index"
    $idToSpdx[[string]$package.id] = $spdxId

    $licenseDeclared = if ([string]::IsNullOrWhiteSpace([string]$package.license)) {
        'NOASSERTION'
    } else {
        [string]$package.license
    }

    $purlName = [Uri]::EscapeDataString([string]$package.name)
    $purlVersion = [Uri]::EscapeDataString([string]$package.version)

    $packages += [ordered]@{
        SPDXID = $spdxId
        name = [string]$package.name
        versionInfo = [string]$package.version
        downloadLocation = 'NOASSERTION'
        filesAnalyzed = $false
        licenseConcluded = 'NOASSERTION'
        licenseDeclared = $licenseDeclared
        copyrightText = 'NOASSERTION'
        externalRefs = @(
            [ordered]@{
                referenceCategory = 'PACKAGE-MANAGER'
                referenceType = 'purl'
                referenceLocator = "pkg:cargo/$purlName@$purlVersion"
            }
        )
    }
}

$documentDescribes = @()
foreach ($workspaceMember in @($metadata.workspace_members)) {
    $key = [string]$workspaceMember
    if ($idToSpdx.ContainsKey($key)) {
        $documentDescribes += $idToSpdx[$key]
    }
}
if ($documentDescribes.Count -eq 0) {
    throw 'Cargo metadata did not identify any workspace packages.'
}

$relationships = @()
$seenRelationships = @{}
if ($metadata.resolve -and $metadata.resolve.nodes) {
    foreach ($node in @($metadata.resolve.nodes)) {
        $fromKey = [string]$node.id
        if (-not $idToSpdx.ContainsKey($fromKey)) {
            continue
        }

        foreach ($dependency in @($node.deps)) {
            $toKey = [string]$dependency.pkg
            if (-not $idToSpdx.ContainsKey($toKey)) {
                continue
            }

            $fromSpdx = $idToSpdx[$fromKey]
            $toSpdx = $idToSpdx[$toKey]
            $dedupeKey = "$fromSpdx->$toSpdx"
            if ($seenRelationships.ContainsKey($dedupeKey)) {
                continue
            }
            $seenRelationships[$dedupeKey] = $true

            $relationships += [ordered]@{
                spdxElementId = $fromSpdx
                relationshipType = 'DEPENDS_ON'
                relatedSpdxElement = $toSpdx
            }
        }
    }
}

$commitDateText = (& git -C $RepoRoot show -s --format=%cI $SourceCommit).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "git show failed with exit code $LASTEXITCODE"
}
$created = [DateTimeOffset]::Parse($commitDateText).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
$commitLower = $SourceCommit.ToLowerInvariant()

$document = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = "Doki-Dango-$($commitLower.Substring(0, 12))"
    documentNamespace = "https://github.com/Herzchens/Doki-Dango/spdx/$commitLower"
    comment = "Generated from locked Cargo metadata for source commit $commitLower."
    creationInfo = [ordered]@{
        created = $created
        creators = @('Tool: Doki-Dango New-CargoSpdxSbom.ps1')
    }
    documentDescribes = $documentDescribes
    packages = $packages
    relationships = $relationships
}

$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutputPath, ($document | ConvertTo-Json -Depth 12), $utf8NoBom)

Write-Host "SPDX SBOM: $OutputPath"
Write-Host "SPDX packages: $($packages.Count)"
Write-Host "Workspace packages described: $($documentDescribes.Count)"
