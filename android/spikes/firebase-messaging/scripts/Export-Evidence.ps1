[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$EvidenceRoot = Join-Path $RepoRoot 'artifacts\b\evidence'
$PackageName = 'dev.dokidango.bharness'

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
$content = (& $adb exec-out run-as $PackageName cat files/b-evidence.jsonl 2>$null | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read B evidence from the debug app.'
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$path = Join-Path $EvidenceRoot ("b-runtime-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
[IO.File]::WriteAllText($path, $content.TrimEnd() + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

Write-Host "B runtime evidence: $path"
