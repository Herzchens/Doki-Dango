[CmdletBinding()]
param(
    [string]$BaseRef,
    [string]$HeadSha,
    [string]$EventName,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Resolve-RepositoryRoot {
    $gitOutput = (& git rev-parse --show-toplevel 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
        throw "Failed to resolve repository root using git (exit code $exitCode): $gitOutput"
    }
    return (Resolve-Path -LiteralPath $gitOutput).Path
}

function Get-AffectedAreasFromPaths {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$Paths = @()
    )

    $runDotNet = $false
    $runRustHarness = $false
    $runHost = $false
    $runAndroid = $false
    $runPackage = $false

    if ($null -eq $Paths -or $Paths.Count -eq 0) {
        # Empty change list (or failed comparison) fails closed: run all jobs
        return @{
            run_dotnet       = $true
            run_rust_harness = $true
            run_host         = $true
            run_android      = $true
            run_package      = $true
        }
    }

    foreach ($rawPath in $Paths) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }
        $normalized = $rawPath.Trim().Replace('\', '/')

        if ($normalized.StartsWith('.github/')) {
            $runDotNet = $true
            $runRustHarness = $true
            $runHost = $true
            $runAndroid = $true
            $runPackage = $true
        }
        elseif ($normalized.StartsWith('docs/')) {
            # Documentation changes alone do not trigger expensive platform builds.
            continue
        }
        elseif ($normalized.StartsWith('shared/')) {
            $runHost = $true
            $runAndroid = $true
            $runPackage = $true
        }
        elseif ($normalized.StartsWith('integration/')) {
            $runHost = $true
            $runAndroid = $true
        }
        elseif ($normalized.StartsWith('android/')) {
            $runAndroid = $true
        }
        elseif ($normalized -eq 'Cargo.toml' -or $normalized -eq 'Cargo.lock') {
            $runHost = $true
            $runPackage = $true
        }
        elseif ($normalized -eq 'rust-toolchain.toml') {
            $runRustHarness = $true
            $runHost = $true
            $runPackage = $true
        }
        elseif ($normalized.StartsWith('windows/spikes/notification-listener-dotnet/')) {
            $runDotNet = $true
        }
        elseif ($normalized.StartsWith('windows/spikes/notification-listener-rust/')) {
            $runRustHarness = $true
        }
        elseif ($normalized.StartsWith('windows/host/') -or
                $normalized.StartsWith('windows/packaging/') -or
                $normalized.StartsWith('windows/scripts/package/') -or
                $normalized.StartsWith('windows/scripts/release/') -or
                $normalized.StartsWith('windows/tests/packaging/') -or
                $normalized.StartsWith('windows/tests/credential-protection/')) {
            $runHost = $true
            $runPackage = $true
        }
        elseif ($normalized.StartsWith('windows/')) {
            # Unknown / general windows tree change: run all Windows jobs
            $runDotNet = $true
            $runRustHarness = $true
            $runHost = $true
            $runPackage = $true
        }
        else {
            # Unknown root file or directory: fail-closed, run everything
            $runDotNet = $true
            $runRustHarness = $true
            $runHost = $true
            $runAndroid = $true
            $runPackage = $true
        }
    }

    # If package is required, host workspace is a required prerequisite.
    if ($runPackage) {
        $runHost = $true
    }

    return @{
        run_dotnet       = $runDotNet
        run_rust_harness = $runRustHarness
        run_host         = $runHost
        run_android      = $runAndroid
        run_package      = $runPackage
    }
}

function Get-ChangedFilesFromGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$CandidateBase,
        [Parameter(Mandatory = $true)]
        [string]$CandidateHead
    )

    $resolvedBase = $null

    # 1. Verify CandidateBase immediately
    $null = & git -C $RepoRoot rev-parse --verify "${CandidateBase}^{commit}" 2>$null
    $baseExit = $LASTEXITCODE
    if ($baseExit -eq 0) {
        $resolvedBase = $CandidateBase
    }
    else {
        # Fallback to origin/<CandidateBase>
        $originCandidate = "origin/$CandidateBase"
        $null = & git -C $RepoRoot rev-parse --verify "${originCandidate}^{commit}" 2>$null
        $originExit = $LASTEXITCODE
        if ($originExit -eq 0) {
            $resolvedBase = $originCandidate
        }
    }

    if (-not $resolvedBase) {
        Write-Host "Warning: Candidate diff base '$CandidateBase' and 'origin/$CandidateBase' could not be resolved. Failing closed."
        return $null
    }

    # 2. Verify CandidateHead immediately
    $null = & git -C $RepoRoot rev-parse --verify "${CandidateHead}^{commit}" 2>$null
    $headExit = $LASTEXITCODE
    if ($headExit -ne 0) {
        Write-Host "Warning: Candidate diff head '$CandidateHead' could not be resolved (exit code $headExit). Failing closed."
        return $null
    }

    # 3. Diff resolvedBase and CandidateHead immediately
    $diffOutput = @(& git -C $RepoRoot diff --name-only "$resolvedBase" "$CandidateHead" 2>&1)
    $diffExit = $LASTEXITCODE
    if ($diffExit -ne 0) {
        Write-Host "Warning: git diff failed with exit code $diffExit. Output: $diffOutput. Failing closed."
        return $null
    }

    return @($diffOutput | Where-Object { [string]::IsNullOrWhiteSpace($_) -eq $false })
}

function Resolve-CiAffectedAreas {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [string]$EventName,
        [string]$BaseRef,
        [string]$HeadSha
    )

    $effectiveEvent = if ($EventName) { $EventName } else { $env:GITHUB_EVENT_NAME }

    if ($effectiveEvent -eq 'workflow_dispatch') {
        Write-Host "Event is workflow_dispatch: selecting all platform jobs."
        return @{
            run_dotnet       = $true
            run_rust_harness = $true
            run_host         = $true
            run_android      = $true
            run_package      = $true
        }
    }

    $diffBase = $null
    $diffHead = if ($HeadSha) { $HeadSha } else { 'HEAD' }

    if ($effectiveEvent -eq 'pull_request') {
        # In PRs, diff against the target branch base
        $diffBase = if ($BaseRef) { $BaseRef } else { $env:GITHUB_BASE_REF }
        if (-not $diffBase) {
            Write-Host "Warning: BaseRef not specified for pull_request; falling back to origin/main."
            $diffBase = 'origin/main'
        }
    }
    elseif ($effectiveEvent -eq 'push') {
        # On push, diff before..after
        $before = if ($BaseRef) { $BaseRef } else { $env:GITHUB_EVENT_BEFORE }
        if ($before -and $before -ne '0000000000000000000000000000000000000000') {
            $diffBase = $before
        }
        else {
            Write-Host "Notice: Initial commit or missing before SHA on push; diffing against HEAD~1."
            $diffBase = 'HEAD~1'
        }
    }
    else {
        $diffBase = if ($BaseRef) { $BaseRef } else { 'origin/main' }
    }

    $changedFiles = Get-ChangedFilesFromGit -RepoRoot $RepoRoot -CandidateBase $diffBase -CandidateHead $diffHead
    if ($null -eq $changedFiles) {
        Write-Host "Failing closed due to Git resolution or diff failure: selecting all jobs."
        return @{
            run_dotnet       = $true
            run_rust_harness = $true
            run_host         = $true
            run_android      = $true
            run_package      = $true
        }
    }

    Write-Host "Detected $($changedFiles.Count) changed files."
    return Get-AffectedAreasFromPaths $changedFiles
}

function Run-SelfTests {
    Write-Host "Running Get-CiAffectedAreas self-tests..."
    $selfTestRepo = Resolve-RepositoryRoot

    function Assert-Result {
        param(
            [string]$Name,
            [hashtable]$Actual,
            [hashtable]$Expected
        )

        foreach ($key in @('run_dotnet', 'run_rust_harness', 'run_host', 'run_android', 'run_package')) {
            if ($Actual[$key] -ne $Expected[$key]) {
                throw "SelfTest '$Name' failed for '$key': expected $($Expected[$key]), got $($Actual[$key])"
            }
        }
        Write-Host "  [PASS] $Name"
    }

    # 1. windows/host/src/main.rs
    Assert-Result -Name "windows/host/src/main.rs" `
        -Actual (Get-AffectedAreasFromPaths @('windows/host/src/main.rs')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $false; run_host = $true; run_android = $false; run_package = $true }

    # 2. windows/spikes/notification-listener-dotnet/...
    Assert-Result -Name "windows/spikes/notification-listener-dotnet" `
        -Actual (Get-AffectedAreasFromPaths @('windows/spikes/notification-listener-dotnet/Program.cs')) `
        -Expected @{ run_dotnet = $true; run_rust_harness = $false; run_host = $false; run_android = $false; run_package = $false }

    # 3. windows/spikes/notification-listener-rust/...
    Assert-Result -Name "windows/spikes/notification-listener-rust" `
        -Actual (Get-AffectedAreasFromPaths @('windows/spikes/notification-listener-rust/src/main.rs')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $true; run_host = $false; run_android = $false; run_package = $false }

    # 4. android/spikes/firebase-messaging/...
    Assert-Result -Name "android/spikes/firebase-messaging" `
        -Actual (Get-AffectedAreasFromPaths @('android/spikes/firebase-messaging/app/src/main/kotlin/App.kt')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $false; run_host = $false; run_android = $true; run_package = $false }

    # 5. shared/protocol/fixtures/v1.json
    Assert-Result -Name "shared/protocol/fixtures/v1.json" `
        -Actual (Get-AffectedAreasFromPaths @('shared/protocol/fixtures/v1.json')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $false; run_host = $true; run_android = $true; run_package = $true }

    # 6. integration/notification-mirroring/...
    Assert-Result -Name "integration/notification-mirroring" `
        -Actual (Get-AffectedAreasFromPaths @('integration/notification-mirroring/Start-Tracer.ps1')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $false; run_host = $true; run_android = $true; run_package = $false }

    # 7. docs/adr/...
    Assert-Result -Name "docs/adr/0001.md" `
        -Actual (Get-AffectedAreasFromPaths @('docs/adr/0001.md')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $false; run_host = $false; run_android = $false; run_package = $false }

    # 8. .github/workflows/ci.yml
    Assert-Result -Name ".github/workflows/ci.yml" `
        -Actual (Get-AffectedAreasFromPaths @('.github/workflows/ci.yml')) `
        -Expected @{ run_dotnet = $true; run_rust_harness = $true; run_host = $true; run_android = $true; run_package = $true }

    # 9. Cargo.toml
    Assert-Result -Name "Cargo.toml" `
        -Actual (Get-AffectedAreasFromPaths @('Cargo.toml')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $false; run_host = $true; run_android = $false; run_package = $true }

    # 10. Cargo.lock
    Assert-Result -Name "Cargo.lock" `
        -Actual (Get-AffectedAreasFromPaths @('Cargo.lock')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $false; run_host = $true; run_android = $false; run_package = $true }

    # 11. rust-toolchain.toml
    Assert-Result -Name "rust-toolchain.toml" `
        -Actual (Get-AffectedAreasFromPaths @('rust-toolchain.toml')) `
        -Expected @{ run_dotnet = $false; run_rust_harness = $true; run_host = $true; run_android = $false; run_package = $true }

    # 12. Unknown root file
    Assert-Result -Name "unknown-root-file.txt" `
        -Actual (Get-AffectedAreasFromPaths @('unknown-root-file.txt')) `
        -Expected @{ run_dotnet = $true; run_rust_harness = $true; run_host = $true; run_android = $true; run_package = $true }

    # 13. Empty change list fails closed
    Assert-Result -Name "empty-paths-fail-closed" `
        -Actual (Get-AffectedAreasFromPaths @()) `
        -Expected @{ run_dotnet = $true; run_rust_harness = $true; run_host = $true; run_android = $true; run_package = $true }

    # 14. workflow_dispatch event selects all jobs
    $dispatchResult = Resolve-CiAffectedAreas -RepoRoot $selfTestRepo -EventName 'workflow_dispatch'
    Assert-Result -Name "workflow_dispatch-all-jobs" `
        -Actual $dispatchResult `
        -Expected @{ run_dotnet = $true; run_rust_harness = $true; run_host = $true; run_android = $true; run_package = $true }

    # 15. Real fail-closed native Git resolution failure (deliberately nonexistent base ref)
    $gitBaseFail = Resolve-CiAffectedAreas -RepoRoot $selfTestRepo -EventName 'pull_request' `
        -BaseRef 'deliberately-nonexistent-base-deadbeef' -HeadSha 'HEAD'
    Assert-Result -Name "real-fail-closed-git-base-failure" `
        -Actual $gitBaseFail `
        -Expected @{ run_dotnet = $true; run_rust_harness = $true; run_host = $true; run_android = $true; run_package = $true }

    # 16. Real fail-closed native Git resolution failure (deliberately nonexistent head SHA)
    $gitHeadFail = Resolve-CiAffectedAreas -RepoRoot $selfTestRepo -EventName 'pull_request' `
        -BaseRef 'HEAD' -HeadSha 'deliberately-nonexistent-head-deadbeef'
    Assert-Result -Name "real-fail-closed-git-head-failure" `
        -Actual $gitHeadFail `
        -Expected @{ run_dotnet = $true; run_rust_harness = $true; run_host = $true; run_android = $true; run_package = $true }

    Write-Host "All Get-CiAffectedAreas self-tests passed successfully."
}

if ($SelfTest) {
    Run-SelfTests
    exit 0
}

# Live execution mode
$repoRoot = Resolve-RepositoryRoot
$areas = Resolve-CiAffectedAreas -RepoRoot $repoRoot -EventName $EventName -BaseRef $BaseRef -HeadSha $HeadSha

Write-Host "=== AFFECTED AREA DETECTOR OUTPUTS ==="
foreach ($key in ($areas.Keys | Sort-Object)) {
    Write-Host ("  {0} = {1}" -f $key, $areas[$key])
}

if ($env:GITHUB_OUTPUT) {
    foreach ($key in $areas.Keys) {
        "$key=$($areas[$key].ToString().ToLowerInvariant())" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
}
