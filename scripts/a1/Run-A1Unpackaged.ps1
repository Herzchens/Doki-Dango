[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Project = Join-Path $RepoRoot 'src\a1\DokiDango.A1Harness\DokiDango.A1Harness.csproj'

& dotnet run --no-build --project $Project -c $Configuration
if ($LASTEXITCODE -ne 0) {
    throw "A1 unpackaged harness exited with code $LASTEXITCODE"
}
