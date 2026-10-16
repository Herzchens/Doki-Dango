[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path

$violations = @()

function Add-Violation([string]$File, [int]$Line, [string]$Message) {
    $script:violations += [pscustomobject]@{
        File    = $File
        Line    = $Line
        Message = $Message
    }
}

# 1. Cargo.toml path = dependency inspection
$cargoFiles = @(git -C $RepoRoot ls-files '*Cargo.toml')
foreach ($relCargo in $cargoFiles) {
    $absCargo = Join-Path $RepoRoot $relCargo
    $cargoDir = Split-Path -Parent $absCargo
    $lines = Get-Content -LiteralPath $absCargo

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineText = $lines[$i]
        if ($lineText -match 'path\s*=\s*"([^"]+)"') {
            $depRel = $matches[1]
            $resolvedDep = [IO.Path]::GetFullPath((Join-Path $cargoDir $depRel))
            if (-not $resolvedDep.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
                Add-Violation $relCargo ($i + 1) "Dependency points outside repository root: $depRel"
                continue
            }

            $depRepoRel = $resolvedDep.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            $sourceRepoRel = $relCargo -replace '\\', '/'

            # Check: Windows cannot depend on Android
            if ($sourceRepoRel -match '^windows/' -and $depRepoRel -match '^android/') {
                Add-Violation $relCargo ($i + 1) "Windows crate depends on Android path: $depRepoRel"
            }
            # Check: Android cannot depend on Windows
            if ($sourceRepoRel -match '^android/' -and $depRepoRel -match '^windows/') {
                Add-Violation $relCargo ($i + 1) "Android project depends on Windows path: $depRepoRel"
            }
            # Check: shared cannot depend on a platform
            if ($sourceRepoRel -match '^shared/' -and ($depRepoRel -match '^windows/' -or $depRepoRel -match '^android/')) {
                Add-Violation $relCargo ($i + 1) "Shared component depends on platform path: $depRepoRel"
            }
            # Check: code outside spikes cannot depend on spikes
            if ($sourceRepoRel -notmatch 'spikes/' -and $depRepoRel -match 'spikes/') {
                Add-Violation $relCargo ($i + 1) "Production/test code depends on spike internals: $depRepoRel"
            }
            # Check: spike A cannot depend on spike B
            if ($sourceRepoRel -match '(windows|android)/spikes/([^/]+)/') {
                $sourceSpike = "$($matches[1])/spikes/$($matches[2])"
                if ($depRepoRel -match '(windows|android)/spikes/([^/]+)/') {
                    $depSpike = "$($matches[1])/spikes/$($matches[2])"
                    if ($sourceSpike -ne $depSpike) {
                        Add-Violation $relCargo ($i + 1) "Spike '$sourceSpike' depends on another spike '$depSpike'"
                    }
                }
            }
        }
    }
}

# 2. Tracked PowerShell path reference inspection
$psFiles = @(git -C $RepoRoot ls-files '*.ps1' '*.psm1')
foreach ($relPs in $psFiles) {
    $normPs = $relPs -replace '\\', '/'
    # Skip this boundary test script itself
    if ($normPs -eq '.github/scripts/Test-RepositoryBoundaries.ps1') {
        continue
    }

    $absPs = Join-Path $RepoRoot $relPs
    $lines = Get-Content -LiteralPath $absPs

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineText = $lines[$i]

        # Ignore comments
        if ($lineText -match '^\s*#') {
            continue
        }

        # Check: Windows non-spike code cannot depend on Android or any spikes
        if ($normPs -match '^windows/' -and $normPs -notmatch '^windows/spikes/') {
            if ($lineText -match '(?i)android[\\/]') {
                Add-Violation $relPs ($i + 1) "Windows code references Android path: $lineText"
            }
            if ($lineText -match '(?i)spikes[\\/]') {
                Add-Violation $relPs ($i + 1) "Windows code references spike path: $lineText"
            }
        }

        # Check: Android non-spike code cannot depend on Windows or any spikes
        if ($normPs -match '^android/' -and $normPs -notmatch '^android/spikes/') {
            if ($lineText -match '(?i)windows[\\/]') {
                Add-Violation $relPs ($i + 1) "Android code references Windows path: $lineText"
            }
            if ($lineText -match '(?i)spikes[\\/]') {
                Add-Violation $relPs ($i + 1) "Android code references spike path: $lineText"
            }
        }

        # Check: integration code cannot depend on spike internals
        if ($normPs -match '^integration/') {
            if ($lineText -match '(?i)spikes[\\/]') {
                Add-Violation $relPs ($i + 1) "Integration code references spike internals: $lineText"
            }
        }

        # Check: spike A cannot depend on spike B
        if ($normPs -match '^(windows|android)/spikes/([^/]+)/') {
            $currentPlatform = $matches[1]
            $currentSpike = $matches[2]

            # Cannot reference another platform
            $otherPlatform = if ($currentPlatform -eq 'windows') { 'android' } else { 'windows' }
            if ($lineText -match "(?i)$otherPlatform[\\/]") {
                Add-Violation $relPs ($i + 1) "Spike '$currentPlatform/spikes/$currentSpike' references other platform '$otherPlatform': $lineText"
            }

            # Cannot reference another spike in same platform
            if ($lineText -match '(?i)(?:windows|android)[\\/]spikes[\\/]([A-Za-z0-9._-]+)') {
                $referencedSpike = $matches[1]
                if ($referencedSpike -ne $currentSpike) {
                    Add-Violation $relPs ($i + 1) "Spike '$currentPlatform/spikes/$currentSpike' references another spike '$referencedSpike': $lineText"
                }
            }
        }

        # Check: shared code cannot depend on platform or spikes
        if ($normPs -match '^shared/') {
            if ($lineText -match '(?i)(windows|android|spikes)[\\/]') {
                Add-Violation $relPs ($i + 1) "Shared code references platform/spike path: $lineText"
            }
        }
    }
}

# 3. Check report
if ($violations.Count -gt 0) {
    Write-Host "::error::Repository boundary violations detected ($($violations.Count)):"
    foreach ($v in $violations) {
        Write-Host "::error file=$($v.File),line=$($v.Line)::$($v.Message)"
    }
    exit 1
}

Write-Host "Repository boundary checks passed (0 violations across Cargo and PowerShell dependencies)."
exit 0
