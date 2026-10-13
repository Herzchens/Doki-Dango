[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$PackageName = 'dev.dokidango.bharness'
$SecretRoot = Join-Path $env:LOCALAPPDATA 'Doki-Dango\B\secrets'
$FidPath = Join-Path $SecretRoot 'fid.txt'

function Resolve-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    foreach ($root in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if ($root) {
            $candidate = Join-Path $root 'platform-tools\adb.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    throw 'adb.exe not found.'
}

$adb = Resolve-Adb
$fid = (& $adb exec-out run-as $PackageName cat files/b-fid.txt 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fid)) {
    throw 'FID is not available yet. Complete runtime Firebase initialization and register() first.'
}
if ($fid -match '\s') {
    throw 'Captured FID contains unexpected whitespace.'
}

New-Item -ItemType Directory -Force -Path $SecretRoot | Out-Null
[IO.File]::WriteAllText($FidPath, $fid, [Text.UTF8Encoding]::new($false))

$sha = [Security.Cryptography.SHA256]::Create()
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($fid)
    $fingerprint = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
}
finally {
    $sha.Dispose()
}

Write-Host "Captured FID to local secret file: $FidPath"
Write-Host "FID fingerprint: $fingerprint"
