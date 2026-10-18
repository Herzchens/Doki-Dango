[CmdletBinding()]
param(
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$gitOutput = (& git rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitOutput)) {
    throw "Failed to resolve repository root using git."
}
$repoRoot = (Resolve-Path -LiteralPath $gitOutput).Path

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $repoRoot 'windows\packaging\AppxManifest.xml'
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "AppxManifest.xml not found at '$ManifestPath'"
}

[xml]$manifest = Get-Content -LiteralPath $ManifestPath -Raw
$ns = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
$ns.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
$ns.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
$ns.AddNamespace('desktop', 'http://schemas.microsoft.com/appx/manifest/desktop/windows10')

$identity = $manifest.SelectSingleNode('/f:Package/f:Identity', $ns)
$applications = @($manifest.SelectNodes('/f:Package/f:Applications/f:Application', $ns))
$hostApplication = $manifest.SelectSingleNode('/f:Package/f:Applications/f:Application[@Id="Host"]', $ns)
$uiApplication = $manifest.SelectSingleNode('/f:Package/f:Applications/f:Application[@Id="UI"]', $ns)
$uiVisualElements = if ($uiApplication) {
    $uiApplication.SelectSingleNode('uap:VisualElements', $ns)
} else {
    $null
}
$properties = $manifest.SelectSingleNode('/f:Package/f:Properties', $ns)
$startupExtension = $manifest.SelectSingleNode(
    '/f:Package/f:Applications/f:Application[@Id="Host"]/f:Extensions/desktop:Extension[@Category="windows.startupTask"]',
    $ns
)
$startupTask = if ($startupExtension) {
    $startupExtension.SelectSingleNode('desktop:StartupTask', $ns)
} else {
    $null
}

if (-not $identity) { throw 'Missing Package/Identity entry.' }
if ($identity.Name -ne 'ItzHerzchen.DokiDango') { throw "Unexpected package name: $($identity.Name)" }
if ($identity.Publisher -ne 'CN=ItzHerzchen') { throw "Unexpected publisher: $($identity.Publisher)" }
if ($applications.Count -ne 2) { throw "Unexpected application count: $($applications.Count)" }
if (-not $hostApplication) { throw 'Missing Host application entry.' }
if ($hostApplication.Executable -ne 'dokidango.exe') { throw "Unexpected Host executable: $($hostApplication.Executable)" }
if ($hostApplication.EntryPoint -ne 'Windows.FullTrustApplication') { throw "Unexpected Host entry point: $($hostApplication.EntryPoint)" }
if (-not $uiApplication) { throw 'Missing UI application entry.' }
if ($uiApplication.Executable -ne 'dokidango-ui.exe') { throw "Unexpected UI executable: $($uiApplication.Executable)" }
if ($uiApplication.EntryPoint -ne 'Windows.FullTrustApplication') { throw "Unexpected UI entry point: $($uiApplication.EntryPoint)" }
if (-not $uiVisualElements) { throw 'Missing UI visual elements.' }
if ($uiVisualElements.AppListEntry -ne 'none') { throw "UI app list entry must be hidden: $($uiVisualElements.AppListEntry)" }
if (-not $properties) { throw 'Missing Package/Properties entry.' }
if ($properties.DisplayName -ne 'Doki-Dango') { throw "Unexpected display name: $($properties.DisplayName)" }
if ($properties.PublisherDisplayName -ne 'ItzHerzchen') { throw "Unexpected publisher display name: $($properties.PublisherDisplayName)" }
if (-not $startupExtension) { throw 'Missing windows.startupTask extension.' }
if ($startupExtension.Executable -ne 'dokidango.exe') { throw "Unexpected startup executable: $($startupExtension.Executable)" }
if ($startupExtension.EntryPoint -ne 'Windows.FullTrustApplication') { throw "Unexpected startup entry point: $($startupExtension.EntryPoint)" }
if (-not $startupTask) { throw 'Missing desktop:StartupTask.' }
if ($startupTask.TaskId -ne 'DokiDangoHostStartup') { throw "Unexpected startup task ID: $($startupTask.TaskId)" }
if ($startupTask.Enabled -ne 'true') { throw "Startup task must be enabled by default: $($startupTask.Enabled)" }
if ($startupTask.DisplayName -ne 'Doki-Dango') { throw "Unexpected startup display name: $($startupTask.DisplayName)" }

Write-Host "Package manifest validation passed: $ManifestPath"
