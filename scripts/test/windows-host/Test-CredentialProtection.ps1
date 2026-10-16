[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root from '$PSScriptRoot' using git."
}
$RepoRoot = (Resolve-Path -LiteralPath $gitOutput).Path
$HarnessRoot = Join-Path $RepoRoot 'tests\harnesses\windows-credential-protection-rust'
$HarnessManifest = Join-Path $HarnessRoot 'Cargo.toml'
$HarnessExe = Join-Path $HarnessRoot 'target\release\doki-dango-credential-protection-harness.exe'
$HarnessLock = Join-Path $HarnessRoot 'Cargo.lock'

$TestRoot = Join-Path $env:TEMP ("Doki-Dango-Credential-Test-{0}-{1}" -f $PID, [Guid]::NewGuid().ToString('N'))
$CredentialPath = Join-Path $TestRoot 'synthetic.dpapi'
$ProductionCredentialPath = Join-Path $env:LOCALAPPDATA 'Doki-Dango\Host\credentials\firebase-service-account.dpapi'

function Get-FileMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            Length = $null
            LastWriteTimeUtc = $null
        }
    }

    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Exists = $true
        Length = $item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.Ticks
    }
}

function Assert-MetadataEqual {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    if ($Before.Exists -ne $After.Exists -or
        $Before.Length -ne $After.Length -or
        $Before.LastWriteTimeUtc -ne $After.LastWriteTimeUtc) {
        throw 'Production credential slot changed during synthetic credential testing.'
    }
}

function Invoke-CredentialHarness {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Path,
        [byte[]]$InputBytes = @()
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $HarnessExe
    $startInfo.Arguments = "$Command `"$Path`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw "Failed to start credential harness command: $Command"
    }

    if ($InputBytes.Count -gt 0) {
        $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Count)
        $process.StandardInput.BaseStream.Flush()
    }
    $process.StandardInput.Close()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout.Trim()
        StdErr = $stderr.Trim()
    }
}

function Contains-ByteSequence {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Haystack,
        [Parameter(Mandatory = $true)][byte[]]$Needle
    )

    if ($Needle.Count -eq 0 -or $Needle.Count -gt $Haystack.Count) {
        return $false
    }

    for ($i = 0; $i -le $Haystack.Count - $Needle.Count; $i++) {
        $matches = $true
        for ($j = 0; $j -lt $Needle.Count; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $matches = $false
                break
            }
        }

        if ($matches) {
            return $true
        }
    }

    return $false
}

$productionBefore = Get-FileMetadata -Path $ProductionCredentialPath

try {
    Write-Host '=== TEST: WINDOWS CREDENTIAL PROTECTION ==='

    & cargo build --manifest-path $HarnessManifest --release
    if ($LASTEXITCODE -ne 0) {
        throw "Credential harness build failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path -LiteralPath $HarnessExe)) {
        throw "Credential harness executable not found: $HarnessExe"
    }

    New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

    $marker = 'DOKI-CREDENTIAL-SYNTHETIC-'
    $syntheticSecret = $marker + ('X' * 4096) + '-END'
    $secretBytes = [Text.Encoding]::UTF8.GetBytes($syntheticSecret)
    $markerBytes = [Text.Encoding]::UTF8.GetBytes($marker)

    $write = Invoke-CredentialHarness -Command 'write' -Path $CredentialPath -InputBytes $secretBytes
    if ($write.ExitCode -ne 0 -or $write.StdOut -notmatch '^WRITE_OK bytes=') {
        throw "Credential write failed. Exit=$($write.ExitCode) stderr=$($write.StdErr)"
    }

    if (-not (Test-Path -LiteralPath $CredentialPath)) {
        throw 'Protected credential file was not created.'
    }

    $protectedBytes = [IO.File]::ReadAllBytes($CredentialPath)
    if ($protectedBytes.Count -le 10) {
        throw "Protected credential file is unexpectedly small: $($protectedBytes.Count) bytes"
    }

    $magic = [byte[]](68, 79, 75, 73, 45, 67, 82, 69, 68, 1)
    for ($i = 0; $i -lt $magic.Count; $i++) {
        if ($protectedBytes[$i] -ne $magic[$i]) {
            throw 'Credential file magic/version prefix is invalid.'
        }
    }

    if (Contains-ByteSequence -Haystack $protectedBytes -Needle $markerBytes) {
        throw 'Plaintext synthetic credential marker is present in the protected file.'
    }

    $verify = Invoke-CredentialHarness -Command 'verify' -Path $CredentialPath -InputBytes $secretBytes
    if ($verify.ExitCode -ne 0 -or $verify.StdOut -notmatch '^VERIFY_OK bytes=') {
        throw "Cross-process credential verification failed. Exit=$($verify.ExitCode) stderr=$($verify.StdErr)"
    }

    $tamperedBytes = [byte[]]$protectedBytes.Clone()
    $tamperIndex = [Math]::Max(10, [int]($tamperedBytes.Count / 2))
    $tamperedBytes[$tamperIndex] = $tamperedBytes[$tamperIndex] -bxor 0x5A
    [IO.File]::WriteAllBytes($CredentialPath, $tamperedBytes)

    $tamperedVerify = Invoke-CredentialHarness -Command 'verify' -Path $CredentialPath -InputBytes $secretBytes
    if ($tamperedVerify.ExitCode -eq 0) {
        throw 'Tampered protected credential was accepted.'
    }

    $rewrite = Invoke-CredentialHarness -Command 'write' -Path $CredentialPath -InputBytes $secretBytes
    if ($rewrite.ExitCode -ne 0) {
        throw "Credential rewrite after tamper failed. Exit=$($rewrite.ExitCode) stderr=$($rewrite.StdErr)"
    }

    $verifyAgain = Invoke-CredentialHarness -Command 'verify' -Path $CredentialPath -InputBytes $secretBytes
    if ($verifyAgain.ExitCode -ne 0) {
        throw "Credential verification after rewrite failed. Exit=$($verifyAgain.ExitCode) stderr=$($verifyAgain.StdErr)"
    }

    $delete = Invoke-CredentialHarness -Command 'delete' -Path $CredentialPath
    if ($delete.ExitCode -ne 0 -or $delete.StdOut -notmatch '^DELETE_OK deleted=true$') {
        throw "Credential delete failed. Exit=$($delete.ExitCode) stderr=$($delete.StdErr)"
    }

    if (Test-Path -LiteralPath $CredentialPath) {
        throw 'Protected credential file still exists after delete.'
    }

    $productionAfter = Get-FileMetadata -Path $ProductionCredentialPath
    Assert-MetadataEqual -Before $productionBefore -After $productionAfter

    Write-Host "Synthetic credential bytes: $($secretBytes.Count)"
    Write-Host "Protected file bytes: $($protectedBytes.Count)"
    Write-Host 'Plaintext marker absent from protected file: PASS'
    Write-Host 'Cross-process current-user roundtrip: PASS'
    Write-Host 'Tamper rejection: PASS'
    Write-Host 'Rewrite after tamper: PASS'
    Write-Host 'Delete/cleanup: PASS'
    Write-Host 'Production credential slot untouched: PASS'
    Write-Host '=== ALL CREDENTIAL PROTECTION TESTS PASSED ==='
}
finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $HarnessLock -Force -ErrorAction SilentlyContinue
}
