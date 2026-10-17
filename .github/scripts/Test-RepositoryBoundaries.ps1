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

function Get-TrackedFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $cmdArgs = @('-C', $RepoRoot, 'ls-files', '--') + $Patterns
    $output = & git @cmdArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = $output -join "`n"
        throw "git ls-files failed for $Description with exit code ${LASTEXITCODE}: $msg"
    }

    $files = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($files.Count -eq 0) {
        throw "Expected tracked $Description files in repository, but git ls-files returned none."
    }

    return $files
}

function Test-PathInsideRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedPath
    )

    if ($ResolvedPath -eq $RepoRoot) {
        return $true
    }

    $sep = [IO.Path]::DirectorySeparatorChar
    $prefix = $RepoRoot.TrimEnd($sep) + $sep
    return $ResolvedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Check-PathBoundaries {
    param(
        [string]$SourceRelFile,
        [int]$LineNumber,
        [string]$DepRepoRel,
        [string]$DepDescription
    )

    $sourceRepoRel = $SourceRelFile -replace '\\', '/'
    $depRepoRel = $DepRepoRel -replace '\\', '/'

    # Windows cannot depend on Android
    if ($sourceRepoRel -match '^windows/' -and $depRepoRel -match '^android/') {
        Add-Violation $SourceRelFile $LineNumber "$($DepDescription): Windows component depends on Android path: $depRepoRel"
    }
    # Android cannot depend on Windows
    if ($sourceRepoRel -match '^android/' -and $depRepoRel -match '^windows/') {
        Add-Violation $SourceRelFile $LineNumber "$($DepDescription): Android component depends on Windows path: $depRepoRel"
    }
    # Shared cannot depend on a platform
    if ($sourceRepoRel -match '^shared/' -and ($depRepoRel -match '^windows/' -or $depRepoRel -match '^android/')) {
        Add-Violation $SourceRelFile $LineNumber "$($DepDescription): Shared component depends on platform path: $depRepoRel"
    }
    # Code outside spikes cannot depend on spikes
    if ($sourceRepoRel -notmatch 'spikes/' -and $depRepoRel -match 'spikes/') {
        Add-Violation $SourceRelFile $LineNumber "$($DepDescription): Production/test code depends on spike internals: $depRepoRel"
    }
    # Spike A cannot depend on spike B
    if ($sourceRepoRel -match '^(windows|android)/spikes/([^/]+)/') {
        $sourceSpike = "$($matches[1])/spikes/$($matches[2])"
        if ($depRepoRel -match '^(windows|android)/spikes/([^/]+)/') {
            $depSpike = "$($matches[1])/spikes/$($matches[2])"
            if ($sourceSpike -ne $depSpike) {
                Add-Violation $SourceRelFile $LineNumber "$($DepDescription): Spike '$sourceSpike' depends on another spike '$depSpike'"
            }
        }
    }
}

# 1. Cargo.toml path = dependency inspection
$cargoFiles = Get-TrackedFiles @('*Cargo.toml') 'Cargo manifest'
foreach ($relCargo in $cargoFiles) {
    $absCargo = Join-Path $RepoRoot $relCargo
    $cargoDir = Split-Path -Parent $absCargo
    $lines = Get-Content -LiteralPath $absCargo

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineText = $lines[$i]
        if ($lineText -match 'path\s*=\s*[''"]([^''"]+)[''"]') {
            $depRel = $matches[1]
            $resolvedDep = [IO.Path]::GetFullPath((Join-Path $cargoDir $depRel))
            if (-not (Test-PathInsideRepo $resolvedDep)) {
                Add-Violation $relCargo ($i + 1) "Dependency points outside repository root: $depRel"
                continue
            }

            $depRepoRel = $resolvedDep.Substring($RepoRoot.Length).TrimStart('\', '/')
            Check-PathBoundaries $relCargo ($i + 1) $depRepoRel 'Cargo dependency'
        }
    }
}

# 2. Tracked PowerShell path reference inspection
$psFiles = Get-TrackedFiles @('*.ps1', '*.psm1') 'PowerShell'
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

# 3. Tracked Gradle file dependency inspection
$gradleFiles = Get-TrackedFiles @('*.gradle') 'Gradle'
foreach ($relGradle in $gradleFiles) {
    $absGradle = Join-Path $RepoRoot $relGradle
    $gradleDir = Split-Path -Parent $absGradle
    $lines = Get-Content -LiteralPath $absGradle

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineText = $lines[$i]

        # Ignore comments
        if ($lineText -match '^\s*(?://|/\*|\*)') {
            continue
        }

        # Check file('...') or files('...') or projectDir path references
        if ($lineText -match '(?:file|files|projectDir\s*=)\s*\(?[''"]([^''"]+)[''"]') {
            $rawPath = $matches[1]
            # Skip simple single names without slashes or variables
            if ($rawPath -match '[\\/]') {
                $resolvedPath = [IO.Path]::GetFullPath((Join-Path $gradleDir $rawPath))
                if (-not (Test-PathInsideRepo $resolvedPath)) {
                    Add-Violation $relGradle ($i + 1) "Gradle path points outside repository root: $rawPath"
                    continue
                }

                $depRepoRel = $resolvedPath.Substring($RepoRoot.Length).TrimStart('\', '/')
                Check-PathBoundaries $relGradle ($i + 1) $depRepoRel 'Gradle path reference'
            }
        }

        # Check for cross-platform string mentions
        $normGradle = $relGradle -replace '\\', '/'
        if ($normGradle -match '^android/' -and $lineText -match '(?i)windows[\\/]') {
            Add-Violation $relGradle ($i + 1) "Android Gradle file references Windows path: $lineText"
        }
    }
}

# 4. Tracked .NET project file dependency inspection
$csprojFiles = Get-TrackedFiles @('*.csproj') '.NET project'
foreach ($relCsproj in $csprojFiles) {
    $absCsproj = Join-Path $RepoRoot $relCsproj
    $csprojDir = Split-Path -Parent $absCsproj
    $lines = Get-Content -LiteralPath $absCsproj

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineText = $lines[$i]

        # Ignore comments
        if ($lineText -match '^\s*<!--') {
            continue
        }

        # Check ProjectReference Include, Reference HintPath, or Import Project
        if ($lineText -match '(?:ProjectReference\s+Include|HintPath|Import\s+Project)\s*=\s*"([^"]+)"' -or
            $lineText -match '<HintPath>([^<]+)</HintPath>') {
            $rawPath = $matches[1]
            $resolvedPath = [IO.Path]::GetFullPath((Join-Path $csprojDir $rawPath))
            if (-not (Test-PathInsideRepo $resolvedPath)) {
                Add-Violation $relCsproj ($i + 1) ".NET project reference points outside repository root: $rawPath"
                continue
            }

            $depRepoRel = $resolvedPath.Substring($RepoRoot.Length).TrimStart('\', '/')
            Check-PathBoundaries $relCsproj ($i + 1) $depRepoRel '.NET project reference'
        }

        # Check for cross-platform string mentions
        $normCsproj = $relCsproj -replace '\\', '/'
        if ($normCsproj -match '^windows/' -and $lineText -match '(?i)android[\\/]') {
            Add-Violation $relCsproj ($i + 1) "Windows .NET project references Android path: $lineText"
        }
    }
}

# 5. Check report
if ($violations.Count -gt 0) {
    Write-Host "::error::Repository boundary violations detected ($($violations.Count)):"
    foreach ($v in $violations) {
        Write-Host "::error file=$($v.File),line=$($v.Line)::$($v.Message)"
    }
    exit 1
}

Write-Host "Repository boundary checks passed (0 violations across Cargo, PowerShell, Gradle, and .NET dependencies)."
exit 0
