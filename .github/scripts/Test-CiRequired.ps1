[CmdletBinding()]
param(
    [string]$DetectResult,
    [string]$ValidateResult,
    [string]$ExpectationsJson,
    [string]$ResultsJson,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Evaluate-CiRequired {
    param(
        [string]$DetectResult,
        [string]$ValidateResult,
        [hashtable]$Expectations,
        [hashtable]$Results
    )

    $errors = @()

    # 1. Detector job must succeed
    if ($DetectResult -ne 'success') {
        $errors += "Detector job did not succeed (actual: '$DetectResult', expected: 'success')."
    }

    # 2. Always-run validation job must succeed
    if ($ValidateResult -ne 'success') {
        $errors += "Parse and hygiene validation job did not succeed (actual: '$ValidateResult', expected: 'success')."
    }

    # 3. Check each expensive platform job against detector expectations
    $mapping = [ordered]@{
        'run_dotnet'       = 'windows-dotnet-reference'
        'run_rust_harness' = 'windows-rust-harness'
        'run_host'         = 'windows-host'
        'run_android'      = 'android-fcm-harness'
        'run_package'      = 'windows-package'
    }

    foreach ($outputKey in $mapping.Keys) {
        $jobName = $mapping[$outputKey]

        # Fail-closed check: Expectation key MUST exist
        if (-not $Expectations.ContainsKey($outputKey)) {
            $errors += "Missing expected detector output key: '$outputKey'."
            continue
        }

        $rawVal = $Expectations[$outputKey]
        $expected = $null

        if ($null -eq $rawVal) {
            $errors += "Detector expectation for '$outputKey' is null."
            continue
        }
        elseif ($rawVal -is [bool]) {
            $expected = $rawVal
        }
        elseif ($rawVal -is [string]) {
            $trimmed = $rawVal.Trim()
            if ($trimmed -eq 'true') {
                $expected = $true
            }
            elseif ($trimmed -eq 'false') {
                $expected = $false
            }
            else {
                $errors += "Malformed detector expectation for '$outputKey': expected 'true' or 'false', got '$rawVal'."
                continue
            }
        }
        else {
            $errors += "Invalid detector expectation type for '$outputKey': expected boolean or 'true'/'false' string, got $($rawVal.GetType().FullName)."
            continue
        }

        # Resolve actual job result
        $actual = if ($Results.ContainsKey($jobName)) {
            [string]$Results[$jobName]
        } else {
            'unknown'
        }

        if ($expected) {
            # When required, job MUST succeed
            if ($actual -ne 'success') {
                $errors += "Required job '$jobName' did not succeed (actual: '$actual', expected: 'success')."
            }
        }
        else {
            # When unnecessary, job MUST be skipped. Any other outcome (including unexpected success or failure) is a defect.
            if ($actual -ne 'skipped') {
                $errors += "Unnecessary job '$jobName' was not skipped (actual: '$actual', expected: 'skipped')."
            }
        }
    }

    return @{
        Success = ($errors.Count -eq 0)
        Errors  = $errors
    }
}

function Run-SelfTests {
    Write-Host "Running Test-CiRequired self-tests..."

    function Assert-Evaluation {
        param(
            [string]$TestName,
            [hashtable]$EvalResult,
            [bool]$ExpectedSuccess
        )

        if ($EvalResult.Success -ne $ExpectedSuccess) {
            throw "SelfTest '$TestName' failed: expected Success=$ExpectedSuccess, got $($EvalResult.Success). Errors: $($EvalResult.Errors -join '; ')"
        }
        Write-Host "  [PASS] $TestName"
    }

    $allRequired = @{
        run_dotnet       = $true
        run_rust_harness = $true
        run_host         = $true
        run_android      = $true
        run_package      = $true
    }

    $allSkippedExp = @{
        run_dotnet       = $false
        run_rust_harness = $false
        run_host         = $false
        run_android      = $false
        run_package      = $false
    }

    $allSkippedResults = @{
        'windows-dotnet-reference' = 'skipped'
        'windows-rust-harness'     = 'skipped'
        'windows-host'             = 'skipped'
        'android-fcm-harness'      = 'skipped'
        'windows-package'          = 'skipped'
    }

    $partialRequired = @{
        run_dotnet       = $false
        run_rust_harness = $false
        run_host         = $true
        run_android      = $true
        run_package      = $true
    }

    # === PASS SCENARIOS ===

    # 1. PASS: all required succeed, all unnecessary skipped
    $res1 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $partialRequired `
        -Results @{
            'windows-dotnet-reference' = 'skipped'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Required jobs success and unnecessary jobs skipped" -EvalResult $res1 -ExpectedSuccess $true

    # 2. PASS: docs-only expectations with all expensive jobs skipped
    $res2 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $allSkippedExp `
        -Results $allSkippedResults
    Assert-Evaluation -TestName "Docs-only expectations with all expensive jobs skipped" -EvalResult $res2 -ExpectedSuccess $true

    # 3. PASS: Android-only expected job success + unrelated jobs skipped
    $androidOnlyExp = @{
        run_dotnet       = 'false'
        run_rust_harness = 'false'
        run_host         = 'false'
        run_android      = 'true'
        run_package      = 'false'
    }
    $androidOnlyResults = @{
        'windows-dotnet-reference' = 'skipped'
        'windows-rust-harness'     = 'skipped'
        'windows-host'             = 'skipped'
        'android-fcm-harness'      = 'success'
        'windows-package'          = 'skipped'
    }
    $res3 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $androidOnlyExp `
        -Results $androidOnlyResults
    Assert-Evaluation -TestName "Android-only expected job success + unrelated jobs skipped" -EvalResult $res3 -ExpectedSuccess $true

    # 4. PASS: shared protocol expected Host+Android+package success
    $sharedExp = @{
        run_dotnet       = 'false'
        run_rust_harness = 'false'
        run_host         = 'true'
        run_android      = 'true'
        run_package      = 'true'
    }
    $sharedResults = @{
        'windows-dotnet-reference' = 'skipped'
        'windows-rust-harness'     = 'skipped'
        'windows-host'             = 'success'
        'android-fcm-harness'      = 'success'
        'windows-package'          = 'success'
    }
    $res4 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $sharedExp `
        -Results $sharedResults
    Assert-Evaluation -TestName "Shared protocol expected Host+Android+package success" -EvalResult $res4 -ExpectedSuccess $true

    # === FAIL SCENARIOS ===

    # 5. FAIL: detect failure
    $res5 = Evaluate-CiRequired -DetectResult 'failure' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Detector failure" -EvalResult $res5 -ExpectedSuccess $false

    # 6. FAIL: detector cancelled
    $res6 = Evaluate-CiRequired -DetectResult 'cancelled' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Detector cancelled" -EvalResult $res6 -ExpectedSuccess $false

    # 7. FAIL: validation failure
    $res7 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'failure' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Validation failure" -EvalResult $res7 -ExpectedSuccess $false

    # 8. FAIL: required job failure
    $res8 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'failure'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Required job failure" -EvalResult $res8 -ExpectedSuccess $false

    # 9. FAIL: required job cancelled
    $res9 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'cancelled'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Required job cancelled" -EvalResult $res9 -ExpectedSuccess $false

    # 10. FAIL: required job skipped
    $res10 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'skipped'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Required job skipped" -EvalResult $res10 -ExpectedSuccess $false

    # 11. FAIL: unnecessary job failure
    $res11 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $partialRequired `
        -Results @{
            'windows-dotnet-reference' = 'failure'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Unnecessary job failure" -EvalResult $res11 -ExpectedSuccess $false

    # 12. FAIL: unnecessary job unexpectedly succeeded
    $res12 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $partialRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Unnecessary job unexpectedly succeeded" -EvalResult $res12 -ExpectedSuccess $false

    # 13. FAIL: missing detector output (missing run_android)
    $missingAndroidExp = @{
        run_dotnet       = $false
        run_rust_harness = $false
        run_host         = $true
        run_package      = $true
    }
    $res13 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $missingAndroidExp `
        -Results @{
            'windows-dotnet-reference' = 'skipped'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Missing detector output (run_android)" -EvalResult $res13 -ExpectedSuccess $false

    # 14. FAIL: missing detector output (missing run_package)
    $missingPackageExp = @{
        run_dotnet       = $true
        run_rust_harness = $true
        run_host         = $true
        run_android      = $true
    }
    $res14 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $missingPackageExp `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Missing detector output (run_package)" -EvalResult $res14 -ExpectedSuccess $false

    # 15. FAIL: malformed detector output ('tru')
    $malformedTruExp = @{
        run_dotnet       = $false
        run_rust_harness = $false
        run_host         = $true
        run_android      = 'tru'
        run_package      = $true
    }
    $res15 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $malformedTruExp `
        -Results @{
            'windows-dotnet-reference' = 'skipped'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Malformed detector output ('tru')" -EvalResult $res15 -ExpectedSuccess $false

    # 16. FAIL: malformed detector output (empty string)
    $emptyStrExp = @{
        run_dotnet       = $false
        run_rust_harness = $false
        run_host         = $true
        run_android      = ''
        run_package      = $true
    }
    $res16 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $emptyStrExp `
        -Results @{
            'windows-dotnet-reference' = 'skipped'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Malformed detector output (empty string)" -EvalResult $res16 -ExpectedSuccess $false

    # 17. FAIL: malformed detector output (numeric 1)
    $numericExp = @{
        run_dotnet       = $false
        run_rust_harness = $false
        run_host         = $true
        run_android      = 1
        run_package      = $true
    }
    $res17 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $numericExp `
        -Results @{
            'windows-dotnet-reference' = 'skipped'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Malformed detector output (numeric 1)" -EvalResult $res17 -ExpectedSuccess $false

    # 18. FAIL: malformed detector output (null)
    $nullExp = @{
        run_dotnet       = $false
        run_rust_harness = $false
        run_host         = $true
        run_android      = $null
        run_package      = $true
    }
    $res18 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $nullExp `
        -Results @{
            'windows-dotnet-reference' = 'skipped'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Malformed detector output (null)" -EvalResult $res18 -ExpectedSuccess $false

    # 19. FAIL: unknown result from required job
    $res19 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $partialRequired `
        -Results @{
            'windows-dotnet-reference' = 'skipped'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'unknown_status'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Unknown job result" -EvalResult $res19 -ExpectedSuccess $false

    Write-Host "All Test-CiRequired self-tests passed successfully."
}

if ($SelfTest) {
    Run-SelfTests
    exit 0
}

# Live execution mode
Write-Host "=== CI REQUIRED AGGREGATE GATE ==="
Write-Host "Detector result:  $DetectResult"
Write-Host "Validator result: $ValidateResult"

$expectations = @{}
if ($ExpectationsJson) {
    $expObj = $ExpectationsJson | ConvertFrom-Json
    foreach ($prop in $expObj.PSObject.Properties) {
        $expectations[$prop.Name] = $prop.Value
    }
}

$results = @{}
if ($ResultsJson) {
    $resObj = $ResultsJson | ConvertFrom-Json
    foreach ($prop in $resObj.PSObject.Properties) {
        # If passed needs object: property name is job name and value is object with result or string
        $val = $prop.Value
        $resultStr = if ($val -is [string]) {
            $val
        } elseif ($val.result) {
            [string]$val.result
        } else {
            [string]$val
        }
        $results[$prop.Name] = $resultStr
    }
}

Write-Host "Job expectations:"
foreach ($k in ($expectations.Keys | Sort-Object)) {
    Write-Host ("  {0} = {1}" -f $k, $expectations[$k])
}

Write-Host "Actual job outcomes:"
foreach ($k in ($results.Keys | Sort-Object)) {
    Write-Host ("  {0} = {1}" -f $k, $results[$k])
}

$eval = Evaluate-CiRequired -DetectResult $DetectResult -ValidateResult $ValidateResult `
    -Expectations $expectations -Results $results

if (-not $eval.Success) {
    Write-Host "::error::CI required gate failed with the following errors:"
    foreach ($err in $eval.Errors) {
        Write-Host "::error::$err"
    }
    exit 1
}

Write-Host "CI required gate passed: all required jobs succeeded and conditional skips matched expectations."
exit 0
