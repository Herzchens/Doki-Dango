[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8766
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$PagePath = Join-Path $RepoRoot 'tools\a21\synthetic-notification\index.html'
$Html = [IO.File]::ReadAllText($PagePath)
$Body = [Text.Encoding]::UTF8.GetBytes($Html)

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$listener.Start()

$url = "http://127.0.0.1:$Port/"
Write-Host "A2.1 synthetic notification page: $url"
Write-Host 'Open this URL in Brave/Chrome. Ctrl+C stops the server.'

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)

            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line.Length -eq 0) {
                    break
                }
            }

            $crlf = [string][char]13 + [string][char]10
            $headers = @(
                'HTTP/1.1 200 OK',
                'Content-Type: text/html; charset=utf-8',
                "Content-Length: $($Body.Length)",
                'Cache-Control: no-store',
                'Connection: close',
                '',
                ''
            ) -join $crlf

            $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($Body, 0, $Body.Length)
            $stream.Flush()
        }
        finally {
            $client.Dispose()
        }
    }
}
finally {
    $listener.Stop()
}
