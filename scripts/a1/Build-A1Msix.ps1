[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'arm64')]
    [string]$Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Project = Join-Path $RepoRoot 'src\a1\DokiDango.A1Harness\DokiDango.A1Harness.csproj'
$ManifestTemplate = Join-Path $RepoRoot 'src\a1\packaging\AppxManifest.xml.in'
$AssetsSource = Join-Path $RepoRoot 'src\a1\packaging\Assets'
$ArtifactsRoot = Join-Path $RepoRoot 'artifacts\a1'
$PublishDir = Join-Path $ArtifactsRoot "publish-$Architecture"
$StageDir = Join-Path $ArtifactsRoot "msix-stage-$Architecture"
$PackageDir = Join-Path $ArtifactsRoot 'package'
$MsixPath = Join-Path $PackageDir "DokiDango.A1Harness-$Architecture.msix"
$CerPath = Join-Path $PackageDir 'DokiDango.A1Test.cer'
$Publisher = 'CN=Doki-Dango A1 Test'
$NuGetSource = 'https://api.nuget.org/v3/index.json'

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

    if (${env:ProgramFiles(x86)}) {
        $roots += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin')
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

    $searchedRoots = @(Get-WindowsSdkBinRoots)
    foreach ($kitsRoot in $searchedRoots) {
        $versionDirectories = @(
            Get-ChildItem -LiteralPath $kitsRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
        )

        foreach ($directory in $versionDirectories) {
            foreach ($toolArchitecture in @('x64', 'x86', 'arm64')) {
                $candidate = Join-Path $directory.FullName "$toolArchitecture\$Name"
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        }

        foreach ($toolArchitecture in @('x64', 'x86', 'arm64')) {
            $candidate = Join-Path $kitsRoot "$toolArchitecture\$Name"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    $rootsText = if ($searchedRoots.Count -gt 0) {
        $searchedRoots -join ', '
    }
    else {
        '<none found from registry or default path>'
    }

    throw "$Name not found in Windows SDK. Searched bin roots: $rootsText"
}

$rid = switch ($Architecture) {
    'x64' { 'win-x64' }
    'x86' { 'win-x86' }
    'arm64' { 'win-arm64' }
}

$makeAppx = Find-WindowsSdkTool -Name 'makeappx.exe'
$signTool = Find-WindowsSdkTool -Name 'signtool.exe'

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $PublishDir, $StageDir
New-Item -ItemType Directory -Force -Path $PublishDir, $StageDir, $PackageDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $MsixPath, $CerPath

& dotnet restore $Project -r $rid --source $NuGetSource -p:SelfContained=true
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE"
}

& dotnet publish $Project -c Release -r $rid --self-contained true --no-restore -o $PublishDir
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

Copy-Item (Join-Path $PublishDir '*') $StageDir -Recurse -Force
Copy-Item $AssetsSource (Join-Path $StageDir 'Assets') -Recurse -Force

$manifest = [IO.File]::ReadAllText($ManifestTemplate).Replace('__ARCH__', $Architecture)
[IO.File]::WriteAllText(
    (Join-Path $StageDir 'AppxManifest.xml'),
    $manifest,
    [Text.UTF8Encoding]::new($false))

& $makeAppx pack /d $StageDir /p $MsixPath /o
if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx failed with exit code $LASTEXITCODE"
}

$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.Subject -eq $Publisher -and
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(7)
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    $cert = New-SelfSignedCertificate `
        -Type Custom `
        -KeyUsage DigitalSignature `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @(
            '2.5.29.37={text}1.3.6.1.5.5.7.3.3',
            '2.5.29.19={text}'
        ) `
        -Subject $Publisher `
        -FriendlyName 'Doki-Dango A1 Test'
}

Export-Certificate -Cert $cert -FilePath $CerPath -Force | Out-Null

& $signTool sign /fd SHA256 /sha1 $cert.Thumbprint $MsixPath
if ($LASTEXITCODE -ne 0) {
    throw "SignTool failed with exit code $LASTEXITCODE"
}

Write-Host "MSIX: $MsixPath"
Write-Host "Certificate: $CerPath"
Write-Host "Certificate thumbprint: $($cert.Thumbprint)"
Write-Host 'Install with scripts\a1\Install-A1Msix.ps1 from an elevated PowerShell.'
