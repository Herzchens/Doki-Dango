[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$CargoManifest = Join-Path $RepoRoot 'windows\spikes\notification-listener-rust\Cargo.toml'
$RustExe = Join-Path $RepoRoot 'windows\spikes\notification-listener-rust\target\release\doki-dango-notification-listener-rust.exe'
$ManifestTemplate = Join-Path $RepoRoot 'windows\spikes\notification-listener-rust\packaging\AppxManifest.xml'
$AssetsSource = Join-Path $RepoRoot 'windows\tests\fixtures\notifications\package-assets'
$ArtifactsRoot = Join-Path $RepoRoot 'artifacts\windows\notification-listener-rust'
$StageDir = Join-Path $ArtifactsRoot 'msix-stage-x64'
$PackageDir = Join-Path $ArtifactsRoot 'package'
$MsixPath = Join-Path $PackageDir 'DokiDango.NotificationListenerRust-x64.msix'
$CerPath = Join-Path $PackageDir 'DokiDango.NotificationListenerRust-Test.cer'
$Publisher = 'CN=Doki-Dango Notification Listener Rust Test'

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

$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargo) {
    throw 'cargo.exe not found.'
}

$makeAppx = Find-WindowsSdkTool -Name 'makeappx.exe'
$signTool = Find-WindowsSdkTool -Name 'signtool.exe'

& $cargo.Source build --manifest-path $CargoManifest --release
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $RustExe)) {
    throw "Rust executable not found: $RustExe"
}

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $StageDir
New-Item -ItemType Directory -Force -Path $StageDir, $PackageDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $MsixPath, $CerPath

Copy-Item -LiteralPath $RustExe -Destination (Join-Path $StageDir 'doki-dango-notification-listener-rust.exe')
Copy-Item -LiteralPath $AssetsSource -Destination (Join-Path $StageDir 'Assets') -Recurse -Force
Copy-Item -LiteralPath $ManifestTemplate -Destination (Join-Path $StageDir 'AppxManifest.xml') -Force

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
    $cert = New-SelfSignedCertificate -Type Custom -KeyUsage DigitalSignature -CertStoreLocation 'Cert:\CurrentUser\My' -TextExtension @(
        '2.5.29.37={text}1.3.6.1.5.5.7.3.3',
        '2.5.29.19={text}'
    ) -Subject $Publisher -FriendlyName 'Doki-Dango Notification Listener Rust Test'
}

Export-Certificate -Cert $cert -FilePath $CerPath -Force | Out-Null

& $signTool sign /fd SHA256 /sha1 $cert.Thumbprint $MsixPath
if ($LASTEXITCODE -ne 0) {
    throw "SignTool failed with exit code $LASTEXITCODE"
}

Write-Host "MSIX: $MsixPath"
Write-Host "Certificate: $CerPath"
Write-Host "Certificate thumbprint: $($cert.Thumbprint)"
Write-Host 'Install with windows\spikes\notification-listener-rust\scripts\Install-Msix.ps1 from an elevated PowerShell.'
