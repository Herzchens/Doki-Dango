[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$ManifestPath = Join-Path $RepoRoot 'tests\harnesses\windows-notification-listener-rust\rust\Cargo.toml'

$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargo) {
    throw 'cargo.exe not found. Install the Rust toolchain before running A2.1.'
}

& $cargo.Source build --manifest-path $ManifestPath --release
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed with exit code $LASTEXITCODE"
}

$exe = Join-Path $RepoRoot 'tests\harnesses\windows-notification-listener-rust\rust\target\release\doki-dango-a21-rust-harness.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Rust harness executable not found: $exe"
}

Write-Host "A2.1 Rust harness: $exe"
