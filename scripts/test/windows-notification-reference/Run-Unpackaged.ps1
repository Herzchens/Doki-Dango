[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$Project = Join-Path $RepoRoot 'tests\reference\windows-notification-listener-dotnet\app\DokiDango.A1Harness.csproj'

& dotnet run --no-build --project $Project -c $Configuration
if ($LASTEXITCODE -ne 0) {
    throw "A1 unpackaged harness exited with code $LASTEXITCODE"
}
