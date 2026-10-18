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

        $rawExpected = if ($Expectations.ContainsKey($outputKey)) { $Expectations[$outputKey] } else { $false }
        $expected = if ($rawExpected -is [bool]) {
            $rawExpected
        } elseif ($rawExpected -is [string]) {
            $rawExpected.Trim().ToLowerInvariant() -eq 'true'
        } else {
            $false
        }

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
            # When unnecessary, job should be skipped. Any failure/cancellation/unknown is unacceptable.
            if ($actual -ne 'skipped') {
                if ($actual -ne 'success') {
                    $errors += "Unnecessary job '$jobName' concluded with unexpected failure (actual: '$actual', expected: 'skipped')."
                }
                else {
                    Write-Host "Notice: Unnecessary job '$jobName' executed and succeeded (expected 'skipped')."
                }
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

    $partialRequired = @{
        run_dotnet       = $false
        run_rust_harness = $false
        run_host         = $true
        run_android      = $true
        run_package      = $true
    }

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

    # 2. FAIL: detect failure
    $res2 = Evaluate-CiRequired -DetectResult 'failure' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Detect failure" -EvalResult $res2 -ExpectedSuccess $false

    # 3. FAIL: validation failure
    $res3 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'failure' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Validation failure" -EvalResult $res3 -ExpectedSuccess $false

    # 4. FAIL: required job failure
    $res4 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'failure'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Required job failure" -EvalResult $res4 -ExpectedSuccess $false

    # 5. FAIL: required job cancelled
    $res5 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'cancelled'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Required job cancelled" -EvalResult $res5 -ExpectedSuccess $false

    # 6. FAIL: required job skipped
    $res6 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $allRequired `
        -Results @{
            'windows-dotnet-reference' = 'success'
            'windows-rust-harness'     = 'success'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'skipped'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Required job skipped" -EvalResult $res6 -ExpectedSuccess $false

    # 7. FAIL: unexpected failure from an unnecessary job
    $res7 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $partialRequired `
        -Results @{
            'windows-dotnet-reference' = 'failure'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'success'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Unexpected failure from unnecessary job" -EvalResult $res7 -ExpectedSuccess $false

    # 8. FAIL: unknown result from required job
    $res8 = Evaluate-CiRequired -DetectResult 'success' -ValidateResult 'success' `
        -Expectations $partialRequired `
        -Results @{
            'windows-dotnet-reference' = 'skipped'
            'windows-rust-harness'     = 'skipped'
            'windows-host'             = 'unknown_status'
            'android-fcm-harness'      = 'success'
            'windows-package'          = 'success'
        }
    Assert-Evaluation -TestName "Unknown job result" -EvalResult $res8 -ExpectedSuccess $false

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
