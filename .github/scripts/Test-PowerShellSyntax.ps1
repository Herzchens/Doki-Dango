[CmdletBinding()]
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $RepoRoot) {
    try {
        $gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
    }
    catch {
        Write-Host "::error::Failed to execute git rev-parse from '$PSScriptRoot': $_"
        exit 1
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
        Write-Host "::error::Failed to resolve repository root from '$PSScriptRoot' using git: $gitOutput"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $gitOutput)) {
        Write-Host "::error::Resolved repository root does not exist: '$gitOutput'"
        exit 1
    }
    $RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
}

$cmdArgs = @('-C', $RepoRoot, 'ls-files', '--', '*.ps1', '*.psm1')
try {
    $output = & git @cmdArgs 2>&1
}
catch {
    Write-Host "::error::git ls-files execution failed: $_"
    exit 1
}
if ($LASTEXITCODE -ne 0) {
    $msg = ($output | Out-String).Trim()
    Write-Host "::error::git ls-files failed with exit code ${LASTEXITCODE}: $msg"
    exit 1
}

$files = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
if ($files.Count -eq 0) {
    Write-Host "::error::Expected tracked PowerShell files in repository, but git ls-files returned none."
    exit 1
}

$failed = $false
$parsedCount = 0

foreach ($relPath in $files) {
    $fullPath = Join-Path $RepoRoot $relPath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        Write-Host "::error file=$relPath::File not found on disk: $fullPath"
        $failed = $true
        continue
    }

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $fullPath,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    if ($errors -and $errors.Count -gt 0) {
        foreach ($parseError in @($errors)) {
            $line = $parseError.Extent.StartLineNumber
            $msg = $parseError.Message
            Write-Host "::error file=$relPath,line=$line::$msg"
            $failed = $true
        }
    }

    $parsedCount++
}

$psVersion = $PSVersionTable.PSVersion
if ($failed) {
    Write-Host "::error::PowerShell syntax validation failed under PowerShell $psVersion."
    exit 1
}

Write-Host "Parsed $parsedCount PowerShell scripts with PowerShell $psVersion successfully."
exit 0
