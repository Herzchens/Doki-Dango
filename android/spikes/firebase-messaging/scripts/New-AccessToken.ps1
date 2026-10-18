[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServiceAccountJson,
    [string]$OutputPath = (Join-Path $env:LOCALAPPDATA 'Doki-Dango\FirebaseMessaging\secrets\access-token.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7+ for PEM key import. Run it with pwsh.exe.'
}
if (-not (Test-Path -LiteralPath $ServiceAccountJson)) {
    throw "Service-account JSON not found: $ServiceAccountJson"
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$serviceAccount = Get-Content -LiteralPath $ServiceAccountJson -Raw | ConvertFrom-Json
foreach ($required in @('client_email', 'private_key')) {
    if (-not $serviceAccount.$required) {
        throw "Service-account JSON is missing $required"
    }
}

$tokenUri = if ($serviceAccount.token_uri) { [string]$serviceAccount.token_uri } else { 'https://oauth2.googleapis.com/token' }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$header = @{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
$payload = @{
    iss = [string]$serviceAccount.client_email
    scope = 'https://www.googleapis.com/auth/firebase.messaging'
    aud = $tokenUri
    iat = $now
    exp = $now + 3600
} | ConvertTo-Json -Compress

$encodedHeader = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))
$encodedPayload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload))
$unsignedAssertion = "$encodedHeader.$encodedPayload"

$rsa = [Security.Cryptography.RSA]::Create()
try {
    $rsa.ImportFromPem([string]$serviceAccount.private_key)
    $signature = $rsa.SignData(
        [Text.Encoding]::UTF8.GetBytes($unsignedAssertion),
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
}
finally {
    $rsa.Dispose()
}

$assertion = "$unsignedAssertion.$(ConvertTo-Base64Url $signature)"
$response = Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
    assertion = $assertion
}

if (-not $response.access_token) {
    throw 'OAuth token endpoint returned no access_token.'
}

$expiresIn = if ($response.expires_in) { [int]$response.expires_in } else { 3600 }
$record = [ordered]@{
    access_token = [string]$response.access_token
    token_type = [string]$response.token_type
    expires_at_utc = [DateTimeOffset]::UtcNow.AddSeconds($expiresIn).ToString('o')
}

$parent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$record | ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding utf8

Write-Host "Stored short-lived OAuth token: $OutputPath"
Write-Host "Expires at UTC: $($record.expires_at_utc)"
