[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$CertificatePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$PackageDir = Join-Path $RepoRoot 'artifacts\windows\package'
$Publisher = 'CN=ItzHerzchen'
$FriendlyName = 'Doki-Dango Development Signing'

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

$MsixPath = if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    Join-Path $PackageDir 'Doki-Dango-x64.msix'
} else {
    ConvertTo-AbsolutePath -Path $PackagePath -BasePath $RepoRoot
}
$CerPath = if ([string]::IsNullOrWhiteSpace($CertificatePath)) {
    Join-Path $PackageDir 'Doki-Dango-Development.cer'
} else {
    ConvertTo-AbsolutePath -Path $CertificatePath -BasePath $RepoRoot
}

$cerDirectory = Split-Path -Parent $CerPath
if (-not [string]::IsNullOrWhiteSpace($cerDirectory)) {
    New-Item -ItemType Directory -Force -Path $cerDirectory | Out-Null
}

$markerScript = (Resolve-Path (Join-Path $RepoRoot 'scripts\release\windows\CertificateMarkers.ps1')).Path
. $markerScript
$DevelopmentMarkerUrl = Get-DokiDangoDevelopmentSignerMarkerUrl

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
        foreach ($directory in @(
            Get-ChildItem -LiteralPath $kitsRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
        )) {
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

if (-not (Test-Path -LiteralPath $MsixPath)) {
    throw "MSIX not found: $MsixPath"
}

$signTool = Find-WindowsSdkTool -Name 'signtool.exe'

$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.Subject -eq $Publisher -and
        $_.FriendlyName -eq $FriendlyName -and
        (Test-DokiDangoCertificateHasDevelopmentMarker -Certificate $_) -and
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(7)
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    $certificateParameters = @{
        Type = 'Custom'
        KeyUsage = 'DigitalSignature'
        CertStoreLocation = 'Cert:\CurrentUser\My'
        TextExtension = @(
            '2.5.29.37={text}1.3.6.1.5.5.7.3.3',
            '2.5.29.19={text}',
            "2.5.29.17={text}URL=$DevelopmentMarkerUrl"
        )
        Subject = $Publisher
        FriendlyName = $FriendlyName
    }
    $cert = New-SelfSignedCertificate @certificateParameters
}

Export-Certificate -Cert $cert -FilePath $CerPath -Force | Out-Null

& $signTool sign /fd SHA256 /sha1 $cert.Thumbprint $MsixPath
if ($LASTEXITCODE -ne 0) {
    throw "SignTool failed with exit code $LASTEXITCODE"
}

$signature = Get-AuthenticodeSignature -FilePath $MsixPath
if ($signature.Status -ne 'Valid') {
    throw "Signed package verification failed: $($signature.Status)"
}
if ($signature.SignerCertificate.Subject -ne $Publisher) {
    throw "Unexpected signer subject: $($signature.SignerCertificate.Subject)"
}
if (-not (Test-DokiDangoCertificateHasDevelopmentMarker -Certificate $signature.SignerCertificate)) {
    throw 'Development signer marker is missing from the signed package.'
}

Write-Host "Development-signed MSIX: $MsixPath"
Write-Host "Development certificate: $CerPath"
Write-Host "Certificate thumbprint: $($cert.Thumbprint)"
