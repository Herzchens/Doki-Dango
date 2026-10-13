[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$EvidenceRoot = Join-Path $RepoRoot 'artifacts\a1\evidence'
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$os = Get-CimInstance Win32_OperatingSystem
$sessionId = (Get-Process -Id $PID).SessionId
$sessionName = $env:SESSIONNAME
$isRemote = [bool]($sessionName -and $sessionName -like 'RDP-*')

function Invoke-Capture {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return [ordered]@{
            found = $false
            path = $null
            exitCode = $null
            output = $null
        }
    }

    $output = & $cmd.Source @Arguments 2>&1 | Out-String
    return [ordered]@{
        found = $true
        path = $cmd.Source
        exitCode = $LASTEXITCODE
        output = $output.Trim()
    }
}

function Get-WindowsSdkBinRoots {
    $roots = @()

    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    )) {
        $installedRoots = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($installedRoots -and $installedRoots.KitsRoot10) {
            $roots += (Join-Path $installedRoots.KitsRoot10 'bin')
        }
    }

    if (${env:ProgramFiles(x86)}) {
        $roots += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin')
    }

    return @(
        $roots |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
            ForEach-Object { (Resolve-Path -LiteralPath $_).Path } |
            Select-Object -Unique
    )
}

function Find-WindowsSdkTool {
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($kitsRoot in @(Get-WindowsSdkBinRoots)) {
        $versionDirectories = @(
            Get-ChildItem -LiteralPath $kitsRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
        )

        foreach ($directory in $versionDirectories) {
            foreach ($toolArchitecture in @('x64', 'x86', 'arm64')) {
                $candidate = Join-Path $directory.FullName "$toolArchitecture\$Name"
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        }

        foreach ($toolArchitecture in @('x64', 'x86', 'arm64')) {
            $candidate = Join-Path $kitsRoot "$toolArchitecture\$Name"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    return $null
}

Push-Location $RepoRoot
try {
    $remote = (& git remote get-url origin 2>$null | Out-String).Trim()
    $branch = (& git branch --show-current 2>$null | Out-String).Trim()
    $head = (& git rev-parse HEAD 2>$null | Out-String).Trim()
    $statusLines = @(& git status --porcelain=v1 2>$null)
    $trackedCount = @(& git ls-files 2>$null).Count
}
finally {
    Pop-Location
}

$dotnet = Invoke-Capture -Command 'dotnet' -Arguments @('--info')
$gitVersion = Invoke-Capture -Command 'git' -Arguments @('--version')
$makeAppx = Find-WindowsSdkTool -Name 'makeappx.exe'
$signTool = Find-WindowsSdkTool -Name 'signtool.exe'

$snapshot = [ordered]@{
    timestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
    windows = [ordered]@{
        caption = $os.Caption
        productName = $cv.ProductName
        editionId = $cv.EditionID
        displayVersion = $cv.DisplayVersion
        version = $os.Version
        currentBuildNumber = $cv.CurrentBuildNumber
        ubr = $cv.UBR
        installationType = $cv.InstallationType
        osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
    session = [ordered]@{
        id = $sessionId
        name = $sessionName
        isRemote = $isRemote
        userInteractive = [Environment]::UserInteractive
    }
    powershell = [ordered]@{
        edition = $PSVersionTable.PSEdition
        version = $PSVersionTable.PSVersion.ToString()
    }
    git = [ordered]@{
        remote = $remote
        branch = $branch
        head = $head
        workingTreeClean = ($statusLines.Count -eq 0)
        workingTreeChangeCount = $statusLines.Count
        trackedFileCount = $trackedCount
        version = $gitVersion
    }
    toolchain = [ordered]@{
        dotnet = $dotnet
        makeAppx = $makeAppx
        signTool = $signTool
    }
}

$path = Join-Path $EvidenceRoot ("snapshot-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $path

Write-Host "A1 snapshot: $path"
$snapshot | ConvertTo-Json -Depth 8
