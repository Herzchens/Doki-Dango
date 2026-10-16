[CmdletBinding()]
param()

$script:DokiDangoDevelopmentSignerMarkerUrl = 'https://dokidango.invalid/cert/development-signing/v1'
$script:DokiDangoDevelopmentSignerFriendlyName = 'Doki-Dango Development Signing'

function Get-DokiDangoDevelopmentSignerMarkerUrl {
    return $script:DokiDangoDevelopmentSignerMarkerUrl
}

function Test-DokiDangoCertificateHasDevelopmentMarker {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    foreach ($extension in @($Certificate.Extensions)) {
        if ($extension.Oid.Value -ne '2.5.29.17') {
            continue
        }

        $rawText = [Text.Encoding]::ASCII.GetString($extension.RawData)
        if ($rawText.IndexOf(
            $script:DokiDangoDevelopmentSignerMarkerUrl,
            [StringComparison]::Ordinal
        ) -ge 0) {
            return $true
        }
    }

    return $false
}

function Test-DokiDangoDevelopmentSignerCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    if (Test-DokiDangoCertificateHasDevelopmentMarker -Certificate $Certificate) {
        return $true
    }

    # Transitional compatibility for development certificates created before
    # the marker was embedded. FriendlyName is a certificate-store annotation,
    # so this fallback is only authoritative when the matching local cert exists.
    if (-not [string]::IsNullOrWhiteSpace($Certificate.Thumbprint)) {
        try {
            $stored = Get-Item (
                'Cert:\CurrentUser\My\' + $Certificate.Thumbprint
            ) -ErrorAction Stop

            if ($stored.FriendlyName -eq $script:DokiDangoDevelopmentSignerFriendlyName) {
                return $true
            }
        } catch {
            # No matching local certificate. Embedded marker remains authoritative.
        }
    }

    return $false
}
