[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$ManifestPath = Join-Path $RepoRoot 'windows\spikes\notification-listener-rust\rust\Cargo.toml'

$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargo) {
    throw 'cargo.exe not found. Install the Rust toolchain before running A2.1.'
}

& $cargo.Source build --manifest-path $ManifestPath --release
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed with exit code $LASTEXITCODE"
}

$exe = Join-Path $RepoRoot 'windows\spikes\notification-listener-rust\rust\target\release\doki-dango-a21-rust-harness.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Rust harness executable not found: $exe"
}

Write-Host "A2.1 Rust harness: $exe"
