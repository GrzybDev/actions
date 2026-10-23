#requires -Version 5.1
<#
.SYNOPSIS
Serves a folder as an S3 store on 127.0.0.1 for the tests, as a store behind a proxy receives its requests.

.DESCRIPTION
Answers the calls of the signing scripts (PutObject, GetObject, DeleteObject and ListObjectsV2, path-style) and writes
the port it listens on to its output. Like a store whose proxy forwards a request without a body without its
Content-Length, it refuses a request that signed a header that does not reach it.
#>
param(
    # The folder that holds a folder per bucket.
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Send-Answer($Response, [int]$Status, $Body = '', [string]$Type = 'application/xml') {
    $Response.StatusCode = $Status
    $Response.ContentType = $Type
    $content = $Body
    if ($content -isnot [byte[]]) { $content = [Text.Encoding]::UTF8.GetBytes($Body) }
    $Response.ContentLength64 = $content.Length
    $Response.OutputStream.Write($content, 0, $content.Length)
    $Response.Close()
}

# HttpListener cannot pick a free port itself.
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
Write-Host "Listening on $port"

while ($true) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
        $body = [System.IO.MemoryStream]::new()
        $request.InputStream.CopyTo($body)
        $signed = if ($request.Headers['Authorization'] -match 'SignedHeaders=([^,]+)') { $Matches[1] -split ';' }
        $missing = @($signed | Where-Object {
            -not $request.Headers[$_] -or ($_ -eq 'content-length' -and -not $body.Length)
        })
        if ($missing) {
            Send-Answer $response 400 ("<Error><Code>InvalidRequest</Code>" +
                "<Message>Signed header $($missing[0]) is not present.</Message></Error>")
            continue
        }

        $bucket, $key = [Uri]::UnescapeDataString($request.Url.AbsolutePath.TrimStart('/')) -split '/', 2
        $folder = Join-Path $Root $bucket
        $file = if ($key) { Join-Path $folder $key }
        if ($request.HttpMethod -eq 'PUT') {
            New-Item -ItemType Directory -Force (Split-Path -Parent $file) | Out-Null
            [System.IO.File]::WriteAllBytes($file, $body.ToArray())
            $response.AddHeader('ETag', '"0"')
            Send-Answer $response 200
        }
        elseif ($request.HttpMethod -eq 'DELETE') {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
            Send-Answer $response 204
        }
        elseif ($file -and (Test-Path -LiteralPath $file)) {
            $response.AddHeader('ETag', '"0"')
            $response.AddHeader('Last-Modified', (Get-Item -LiteralPath $file).LastWriteTimeUtc.ToString('R'))
            Send-Answer $response 200 ([System.IO.File]::ReadAllBytes($file)) 'application/octet-stream'
        }
        elseif ($file) {
            Send-Answer $response 404 '<Error><Code>NoSuchKey</Code><Message>No such key.</Message></Error>'
        }
        else {
            $prefix = "$($request.QueryString['prefix'])"
            $base = [System.IO.Path]::GetFullPath($folder).TrimEnd('\') + '\'
            $contents = @(Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $name = $_.FullName.Substring($base.Length).Replace('\', '/')
                if ($name.StartsWith($prefix)) {
                    $modified = $_.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture)
                    "<Contents><Key>$([Security.SecurityElement]::Escape($name))</Key>" +
                        "<LastModified>$modified</LastModified><Size>$($_.Length)</Size></Contents>"
                }
            })
            Send-Answer $response 200 ("<ListBucketResult><Name>$bucket</Name><KeyCount>$($contents.Count)</KeyCount>" +
                "<IsTruncated>false</IsTruncated>$($contents -join '')</ListBucketResult>")
        }
    }
    catch {
        Write-Warning "$($request.HttpMethod) $($request.Url): $($_.Exception.Message)"
        Send-Answer $response 500 '<Error><Code>InternalError</Code><Message>The fake store failed.</Message></Error>'
    }
}
