[CmdletBinding()]
param(
    [string[]]$Components = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root using git."
}
$repoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$toolchainFile = Join-Path $repoRoot 'rust-toolchain.toml'

if (-not (Test-Path -LiteralPath $toolchainFile)) {
    throw "rust-toolchain.toml not found at '$toolchainFile'"
}

$content = Get-Content -LiteralPath $toolchainFile -Raw
if ($content -match 'channel\s*=\s*"([^"]+)"') {
    $channel = $matches[1].Trim()
}
else {
    throw "Could not extract channel from '$toolchainFile'"
}

if ([string]::IsNullOrWhiteSpace($channel)) {
    throw "Channel in '$toolchainFile' is empty or invalid."
}

Write-Host "Installing configured Rust toolchain '$channel'..."
& rustup toolchain install $channel --profile minimal
if ($LASTEXITCODE -ne 0) {
    throw "rustup toolchain install failed with exit code $LASTEXITCODE"
}

& rustup default $channel
if ($LASTEXITCODE -ne 0) {
    throw "rustup default failed with exit code $LASTEXITCODE"
}

$resolvedComponents = @()
foreach ($item in $Components) {
    if ([string]::IsNullOrWhiteSpace($item)) {
        continue
    }
    if ($item -match ',') {
        $resolvedComponents += @($item -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    else {
        $resolvedComponents += $item.Trim()
    }
}

foreach ($component in $resolvedComponents) {
    Write-Host "Adding Rust component '$component'..."
    & rustup component add $component --toolchain $channel
    if ($LASTEXITCODE -ne 0) {
        throw "rustup component add '$component' failed with exit code $LASTEXITCODE"
    }
}

Write-Host "Resolved Rust environment:"
& rustc --version
if ($LASTEXITCODE -ne 0) { throw "rustc --version failed with exit code $LASTEXITCODE" }
& cargo --version
if ($LASTEXITCODE -ne 0) { throw "cargo --version failed with exit code $LASTEXITCODE" }
