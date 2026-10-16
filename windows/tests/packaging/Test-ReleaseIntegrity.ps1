[CmdletBinding()]
param(
    [string]$PackagePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path $RepoRoot 'artifacts\windows\package\Doki-Dango-x64.msix'
}
$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path

$sourceCommit = (& git -C $RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "git rev-parse HEAD failed with exit code $LASTEXITCODE"
}

$tempRoot = Join-Path $env:TEMP ("Doki-Dango-ReleaseIntegrity-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    $integrityScript = Join-Path $RepoRoot 'windows\scripts\release\New-ReleaseIntegrity.ps1'
    $sbomScript = Join-Path $RepoRoot 'windows\scripts\release\New-CargoSpdxSbom.ps1'
    $trustScript = Join-Path $RepoRoot 'windows\scripts\release\Test-ReleaseCandidate.ps1'
    $markerScript = Join-Path $RepoRoot 'windows\scripts\release\CertificateMarkers.ps1'

    & $integrityScript -PackagePath $PackagePath -OutputDirectory $tempRoot -SourceCommit $sourceCommit
    & $sbomScript -OutputPath (Join-Path $tempRoot 'doki-dango.spdx.json') -SourceCommit $sourceCommit

    $integrityPath = Join-Path $tempRoot 'release-integrity.json'
    $shaPath = Join-Path $tempRoot 'SHA256SUMS'
    $sbomPath = Join-Path $tempRoot 'doki-dango.spdx.json'

    foreach ($required in @($integrityPath, $shaPath, $sbomPath)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Release integrity test output missing: $required"
        }
    }

    $integrity = Get-Content -LiteralPath $integrityPath -Raw | ConvertFrom-Json
    $sbom = Get-Content -LiteralPath $sbomPath -Raw | ConvertFrom-Json
    $actualHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToUpperInvariant()
    $shaLine = (Get-Content -LiteralPath $shaPath -Raw).Trim()

    if ([int]$integrity.schemaVersion -ne 1) {
        throw 'Release integrity schema version test failed.'
    }
    if ([string]$integrity.sourceCommit -ne $sourceCommit.ToLowerInvariant()) {
        throw 'Release integrity source commit test failed.'
    }
    if ([string]$integrity.artifact.sha256 -ne $actualHash) {
        throw 'Release integrity SHA256 test failed.'
    }
    if ($shaLine -ne "$actualHash *$([IO.Path]::GetFileName($PackagePath))") {
        throw 'SHA256SUMS content test failed.'
    }
    if ([string]$integrity.packageIdentity.name -ne 'ItzHerzchen.DokiDango') {
        throw 'Package identity name test failed.'
    }
    if ([string]$integrity.packageIdentity.publisher -ne 'CN=ItzHerzchen') {
        throw 'Package identity publisher test failed.'
    }
    if ([string]$integrity.packageIdentity.architecture -ne 'x64') {
        throw 'Package identity architecture test failed.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $PackagePath
    if ([string]$integrity.signature.status -ne $signature.Status.ToString()) {
        throw 'Release integrity signature-status mirror test failed.'
    }

    if ([string]$sbom.spdxVersion -ne 'SPDX-2.3') {
        throw 'SPDX version test failed.'
    }
    if (@($sbom.packages).Count -lt 3) {
        throw 'SPDX package inventory test failed.'
    }
    if (@($sbom.documentDescribes).Count -lt 3) {
        throw 'SPDX workspace description test failed.'
    }

    $fakeThumbprint = '0000000000000000000000000000000000000000'
    $trustRejected = $false
    try {
        & $trustScript -PackagePath $PackagePath -IntegrityManifestPath $integrityPath -SbomPath $sbomPath -SourceCommit $sourceCommit -TrustedSignerThumbprint $fakeThumbprint
    } catch {
        $trustRejected = $true
    }
    if (-not $trustRejected) {
        throw 'Release trust gate failed open with an unapproved signer.'
    }

    . $markerScript
    $syntheticMarkerCert = New-SelfSignedCertificate `
        -Type Custom `
        -KeyUsage DigitalSignature `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @(
            '2.5.29.37={text}1.3.6.1.5.5.7.3.3',
            "2.5.29.17={text}URL=$(Get-DokiDangoDevelopmentSignerMarkerUrl)"
        ) `
        -Subject 'CN=Doki-Dango Marker Test'

    try {
        if (-not (Test-DokiDangoCertificateHasDevelopmentMarker -Certificate $syntheticMarkerCert)) {
            throw 'Development signer marker detection failed.'
        }

        $markerTestFile = Join-Path $tempRoot 'marker-authenticode-test.ps1'
        [IO.File]::WriteAllText(
            $markerTestFile,
            "Write-Host 'marker test'",
            (New-Object Text.UTF8Encoding($false))
        )
        Set-AuthenticodeSignature `
            -FilePath $markerTestFile `
            -Certificate $syntheticMarkerCert `
            -HashAlgorithm SHA256 | Out-Null

        $roundTripSignature = Get-AuthenticodeSignature -LiteralPath $markerTestFile
        if (-not $roundTripSignature.SignerCertificate) {
            throw 'Authenticode marker test did not expose a signer certificate.'
        }
        if (-not (
            Test-DokiDangoCertificateHasDevelopmentMarker `
                -Certificate $roundTripSignature.SignerCertificate
        )) {
            throw 'Development signer marker did not survive Authenticode serialization.'
        }
    } finally {
        Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $syntheticMarkerCert.Thumbprint) -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Release integrity metadata: PASS'
    Write-Host 'SPDX SBOM generation: PASS'
    Write-Host 'Development signer marker Authenticode round-trip: PASS'
    Write-Host 'Release trust gate fail-closed behavior: PASS'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
