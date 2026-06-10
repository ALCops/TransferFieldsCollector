<#
.SYNOPSIS
    Downloads only the Extensions folder from a BC artifact ZIP using HTTP range requests.

.DESCRIPTION
    Instead of downloading the entire BC artifact ZIP (400-500MB), this script uses
    HTTP range requests to read the ZIP central directory and download only entries
    matching a given prefix (default: Extensions/), typically ~165MB.

    Falls back to a full download with selective extraction if range requests fail.

.PARAMETER ArtifactUrl
    URL of the BC artifact (CDN or blob storage).

.PARAMETER OutputPath
    Directory to write extracted .app files to.

.PARAMETER Prefix
    ZIP entry prefix to match. Default: 'Extensions/'.

.PARAMETER TimeoutSec
    HTTP request timeout in seconds. Default: 300.

.OUTPUTS
    PSCustomObject with Success, AppCount, TotalSizeMB, RangeBytes, FullZipSize.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArtifactUrl,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$Prefix = 'Extensions/',

    [int]$TimeoutSec = 300
)

$ErrorActionPreference = 'Stop'

function New-SharedHttpClient {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($script:TimeoutSec)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('TransferFieldsCollector/1.0')
    return $client
}

function Get-HttpContentLength {
    param([System.Net.Http.HttpClient]$Client, [string]$Url)

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Url)
    $response = $Client.SendAsync($request).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null

    $acceptRanges = $null
    if ($response.Headers.Contains('Accept-Ranges')) {
        $acceptRanges = ($response.Headers.GetValues('Accept-Ranges') | Select-Object -First 1)
    }

    $length = $response.Content.Headers.ContentLength
    $response.Dispose()
    $request.Dispose()

    if (-not $length -or $length -le 0) {
        throw "Server did not return Content-Length"
    }

    return [PSCustomObject]@{
        ContentLength = [long]$length
        AcceptRanges  = $acceptRanges
    }
}

function Get-ByteRange {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Url,
        [long]$Start,
        [long]$End
    )

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($Start, $End)

    $response = $Client.SendAsync($request).GetAwaiter().GetResult()

    if ($response.StatusCode -ne [System.Net.HttpStatusCode]::PartialContent) {
        $status = $response.StatusCode
        $response.Dispose()
        $request.Dispose()
        throw "Expected 206 Partial Content, got $([int]$status) $status"
    }

    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $response.Dispose()
    $request.Dispose()
    return $bytes
}

function Save-ByteRange {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Url,
        [long]$Start,
        [long]$End,
        [string]$DestinationFile
    )

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($Start, $End)

    $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()

    if ($response.StatusCode -ne [System.Net.HttpStatusCode]::PartialContent) {
        $status = $response.StatusCode
        $response.Dispose()
        $request.Dispose()
        throw "Expected 206 Partial Content, got $([int]$status) $status"
    }

    $contentStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $fileStream = [System.IO.File]::Create($DestinationFile)
    try {
        $contentStream.CopyTo($fileStream)
    }
    finally {
        $fileStream.Dispose()
        $contentStream.Dispose()
    }

    $bytesWritten = (Get-Item $DestinationFile).Length
    $response.Dispose()
    $request.Dispose()
    return $bytesWritten
}

function Find-EndOfCentralDirectory {
    param([byte[]]$Buffer)

    $sig = @(0x50, 0x4B, 0x05, 0x06)
    for ($i = $Buffer.Length - 22; $i -ge 0; $i--) {
        if ($Buffer[$i] -eq $sig[0] -and $Buffer[$i+1] -eq $sig[1] -and
            $Buffer[$i+2] -eq $sig[2] -and $Buffer[$i+3] -eq $sig[3]) {

            $commentLen = [BitConverter]::ToUInt16($Buffer, $i + 20)
            if ($i + 22 + $commentLen -eq $Buffer.Length) {
                $totalEntries = [BitConverter]::ToUInt16($Buffer, $i + 10)
                $cdSize = [BitConverter]::ToUInt32($Buffer, $i + 12)
                $cdOffset = [BitConverter]::ToUInt32($Buffer, $i + 16)

                if ($totalEntries -eq 0xFFFF -or $cdSize -eq 0xFFFFFFFF -or $cdOffset -eq 0xFFFFFFFF) {
                    throw "ZIP64 format detected (not supported, falling back)"
                }

                return [PSCustomObject]@{
                    CdOffset     = [long]$cdOffset
                    CdSize       = [long]$cdSize
                    TotalEntries = [int]$totalEntries
                }
            }
        }
    }

    throw "End of Central Directory record not found"
}

function Read-CentralDirectory {
    param([byte[]]$Buffer, [int]$ExpectedEntries)

    $entries = [System.Collections.Generic.List[PSCustomObject]]::new($ExpectedEntries)
    $pos = 0
    $cdSig = @(0x50, 0x4B, 0x01, 0x02)

    while ($pos + 46 -le $Buffer.Length) {
        if ($Buffer[$pos] -ne $cdSig[0] -or $Buffer[$pos+1] -ne $cdSig[1] -or
            $Buffer[$pos+2] -ne $cdSig[2] -or $Buffer[$pos+3] -ne $cdSig[3]) {
            break
        }

        $compressionMethod = [BitConverter]::ToUInt16($Buffer, $pos + 10)
        $crc32             = [BitConverter]::ToUInt32($Buffer, $pos + 16)
        $compressedSize    = [BitConverter]::ToUInt32($Buffer, $pos + 20)
        $uncompressedSize  = [BitConverter]::ToUInt32($Buffer, $pos + 24)
        $fileNameLength    = [BitConverter]::ToUInt16($Buffer, $pos + 28)
        $extraFieldLength  = [BitConverter]::ToUInt16($Buffer, $pos + 30)
        $commentLength     = [BitConverter]::ToUInt16($Buffer, $pos + 32)
        $localHeaderOffset = [BitConverter]::ToUInt32($Buffer, $pos + 42)

        $fileName = [System.Text.Encoding]::UTF8.GetString($Buffer, $pos + 46, $fileNameLength)

        $entries.Add([PSCustomObject]@{
            FileName          = $fileName
            CompressionMethod = $compressionMethod
            Crc32             = $crc32
            CompressedSize    = [long]$compressedSize
            UncompressedSize  = [long]$uncompressedSize
            LocalHeaderOffset = [long]$localHeaderOffset
            FileNameLength    = [int]$fileNameLength
        })

        $pos += 46 + $fileNameLength + $extraFieldLength + $commentLength
    }

    return $entries
}

function Expand-ZipEntryFromFile {
    param(
        [System.IO.FileStream]$DataStream,
        [long]$BlockStartOffset,
        [PSCustomObject]$Entry,
        [string]$DestinationPath
    )

    $localOffset = $Entry.LocalHeaderOffset - $BlockStartOffset
    if ($localOffset -lt 0 -or $localOffset + 30 -gt $DataStream.Length) {
        Write-Warning "Entry '$($Entry.FileName)' offset out of range, skipping"
        return $false
    }

    $DataStream.Position = $localOffset

    # Read local file header (30 bytes fixed)
    $header = [byte[]]::new(30)
    $DataStream.Read($header, 0, 30) | Out-Null

    if ($header[0] -ne 0x50 -or $header[1] -ne 0x4B -or
        $header[2] -ne 0x03 -or $header[3] -ne 0x04) {
        Write-Warning "Invalid local header signature for '$($Entry.FileName)', skipping"
        return $false
    }

    $localFileNameLen = [BitConverter]::ToUInt16($header, 26)
    $localExtraLen    = [BitConverter]::ToUInt16($header, 28)
    $dataStart = $localOffset + 30 + $localFileNameLen + $localExtraLen

    if ($dataStart + $Entry.CompressedSize -gt $DataStream.Length) {
        Write-Warning "Compressed data for '$($Entry.FileName)' extends beyond downloaded range, skipping"
        return $false
    }

    # Read compressed data into a per-entry byte array
    $DataStream.Position = $dataStart
    $compressedData = [byte[]]::new($Entry.CompressedSize)
    $totalRead = 0
    while ($totalRead -lt $Entry.CompressedSize) {
        $read = $DataStream.Read($compressedData, $totalRead, $Entry.CompressedSize - $totalRead)
        if ($read -eq 0) { break }
        $totalRead += $read
    }

    $outputFile = Join-Path $DestinationPath ([System.IO.Path]::GetFileName($Entry.FileName.Replace('\', '/')))
    $fs = [System.IO.File]::Create($outputFile)

    try {
        if ($Entry.CompressionMethod -eq 0) {
            $fs.Write($compressedData, 0, $compressedData.Length)
        }
        elseif ($Entry.CompressionMethod -eq 8) {
            $ms = [System.IO.MemoryStream]::new($compressedData)
            $deflate = [System.IO.Compression.DeflateStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $deflate.CopyTo($fs)
            }
            finally {
                $deflate.Dispose()
                $ms.Dispose()
            }
        }
        else {
            Write-Warning "Unsupported compression method $($Entry.CompressionMethod) for '$($Entry.FileName)', skipping"
            $fs.Dispose()
            Remove-Item $outputFile -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    catch {
        $fs.Dispose()
        Remove-Item $outputFile -Force -ErrorAction SilentlyContinue
        throw
    }

    $fs.Dispose()
    return $true
}

function Invoke-FullDownloadFallback {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Url,
        [string]$OutputPath,
        [string]$Prefix
    )

    Write-Host "Downloading full artifact ZIP..."
    $zipFile = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid()).zip"

    try {
        $response = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null

        $contentStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fs = [System.IO.File]::Create($zipFile)
        try {
            $contentStream.CopyTo($fs)
        }
        finally {
            $fs.Dispose()
            $contentStream.Dispose()
        }
        $response.Dispose()

        $zipSize = (Get-Item $zipFile).Length
        Write-Host "Downloaded $([math]::Round($zipSize / 1MB, 1)) MB, extracting $Prefix entries..."

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipFile)
        $normalizedPrefix = $Prefix.Replace('\', '/')
        try {
            $count = 0
            foreach ($entry in $archive.Entries) {
                $normalizedName = $entry.FullName.Replace('\', '/')
                if ($normalizedName.StartsWith($normalizedPrefix, [StringComparison]::Ordinal) -and
                    -not $normalizedName.EndsWith('/')) {
                    $destFile = Join-Path $OutputPath ([System.IO.Path]::GetFileName($entry.FullName.Replace('\', '/')))
                    $entryStream = $entry.Open()
                    $outStream = [System.IO.File]::Create($destFile)
                    try {
                        $entryStream.CopyTo($outStream)
                    }
                    finally {
                        $outStream.Dispose()
                        $entryStream.Dispose()
                    }
                    $count++
                }
            }
        }
        finally {
            $archive.Dispose()
        }

        return [PSCustomObject]@{
            AppCount = $count
            ZipSize  = $zipSize
        }
    }
    finally {
        if (Test-Path $zipFile) {
            Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Main ---

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem


if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$httpClient = New-SharedHttpClient
$tempDataFile = $null
try {
    $rangeBytes = [long]0
    $fullZipSize = [long]0

    try {
        # Step 1: HEAD request
        Write-Host "Checking artifact size..."
        $headInfo = Get-HttpContentLength -Client $httpClient -Url $ArtifactUrl
        $fullZipSize = $headInfo.ContentLength
        Write-Host "Artifact size: $([math]::Round($fullZipSize / 1MB, 1)) MB"

        if ($headInfo.AcceptRanges -and $headInfo.AcceptRanges -ne 'bytes') {
            throw "Server does not support byte range requests (Accept-Ranges: $($headInfo.AcceptRanges))"
        }

        # Step 2: Download EOCD (last 65557 bytes)
        $eocdSize = [math]::Min(65557, $fullZipSize)
        $eocdStart = $fullZipSize - $eocdSize
        Write-Host "Reading ZIP end-of-central-directory..."
        $eocdBuffer = Get-ByteRange -Client $httpClient -Url $ArtifactUrl -Start $eocdStart -End ($fullZipSize - 1)
        $rangeBytes += $eocdBuffer.Length

        $eocd = Find-EndOfCentralDirectory -Buffer $eocdBuffer

        Write-Host "Central directory: $($eocd.TotalEntries) entries, $([math]::Round($eocd.CdSize / 1KB, 1)) KB at offset $($eocd.CdOffset)"

        # Step 3: Download Central Directory
        Write-Host "Reading central directory..."
        $cdBuffer = Get-ByteRange -Client $httpClient -Url $ArtifactUrl -Start $eocd.CdOffset -End ($eocd.CdOffset + $eocd.CdSize - 1)
        $rangeBytes += $cdBuffer.Length

        $allEntries = Read-CentralDirectory -Buffer $cdBuffer -ExpectedEntries $eocd.TotalEntries
        Write-Host "Parsed $($allEntries.Count) entries from central directory"

        # Filter for prefix matches (skip directory entries)
        # ZIP files may use either / or \ as path separator
        $normalizedPrefix = $Prefix.Replace('\', '/')
        $matchingEntries = @($allEntries | Where-Object {
            $normalizedName = $_.FileName.Replace('\', '/')
            $normalizedName.StartsWith($normalizedPrefix, [StringComparison]::Ordinal) -and
            -not $normalizedName.EndsWith('/')
        })

        if ($matchingEntries.Count -eq 0) {
            Write-Host "No entries matching prefix '$Prefix' found"
            return [PSCustomObject]@{
                Success     = $true
                AppCount    = 0
                TotalSizeMB = 0
                RangeBytes  = $rangeBytes
                FullZipSize = $fullZipSize
            }
        }

        Write-Host "Found $($matchingEntries.Count) entries matching '$Prefix'"

        # Step 4: Download contiguous data block to a temp file
        $minOffset = ($matchingEntries | Measure-Object -Property LocalHeaderOffset -Minimum).Minimum
        $maxEnd = ($matchingEntries | ForEach-Object {
            $_.LocalHeaderOffset + 30 + $_.FileNameLength + 256 + $_.CompressedSize
        } | Measure-Object -Maximum).Maximum
        $maxEnd = [math]::Min($maxEnd, $eocd.CdOffset - 1)

        $blockSize = $maxEnd - $minOffset + 1
        Write-Host "Downloading data block: $([math]::Round($blockSize / 1MB, 1)) MB (offset $minOffset to $maxEnd)"

        $tempDataFile = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid()).bin"
        $downloaded = Save-ByteRange -Client $httpClient -Url $ArtifactUrl -Start $minOffset -End $maxEnd -DestinationFile $tempDataFile
        $rangeBytes += $downloaded

        # Step 5: Extract each matching entry from the temp file
        $dataStream = [System.IO.File]::Open($tempDataFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $extractedCount = 0
        $extractedBytes = [long]0

        try {
            foreach ($entry in $matchingEntries) {
                $ok = Expand-ZipEntryFromFile -DataStream $dataStream -BlockStartOffset $minOffset -Entry $entry -DestinationPath $OutputPath
                if ($ok) {
                    $extractedCount++
                    $extractedBytes += $entry.UncompressedSize
                }
            }
        }
        finally {
            $dataStream.Dispose()
        }

        $totalSizeMB = [math]::Round($extractedBytes / 1MB, 1)
        Write-Host ""
        Write-Host "Extracted $extractedCount / $($matchingEntries.Count) entries ($totalSizeMB MB)"
        Write-Host "Downloaded $([math]::Round($rangeBytes / 1MB, 1)) MB via range requests (full ZIP: $([math]::Round($fullZipSize / 1MB, 1)) MB)"
        $savings = [math]::Round((1 - $rangeBytes / $fullZipSize) * 100, 1)
        Write-Host "Bandwidth savings: ${savings}%"

        return [PSCustomObject]@{
            Success     = $true
            AppCount    = $extractedCount
            TotalSizeMB = $totalSizeMB
            RangeBytes  = $rangeBytes
            FullZipSize = $fullZipSize
        }
    }
    catch {
        Write-Host "::warning::Range-based extraction failed: $_"
        Write-Host "Falling back to full download with selective extraction..."

        if (Test-Path $OutputPath) {
            Get-ChildItem $OutputPath -File | Remove-Item -Force
        }

        $fallbackResult = Invoke-FullDownloadFallback -Client $httpClient -Url $ArtifactUrl -OutputPath $OutputPath -Prefix $Prefix

        $outputFiles = Get-ChildItem -Path $OutputPath -Filter "*.app" -File
        $totalSizeMB = [math]::Round(($outputFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 1)

        return [PSCustomObject]@{
            Success     = $true
            AppCount    = $fallbackResult.AppCount
            TotalSizeMB = $totalSizeMB
            RangeBytes  = $null
            FullZipSize = $fallbackResult.ZipSize
        }
    }
}
finally {
    $httpClient.Dispose()
    if ($tempDataFile -and (Test-Path $tempDataFile)) {
        Remove-Item $tempDataFile -Force -ErrorAction SilentlyContinue
    }
}
