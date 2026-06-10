<#
.SYNOPSIS
    Computes a SHA256 hash of only the .al file contents inside a BC .app package.

.DESCRIPTION
    Opens an .app file as a zip archive, reads all .al entries sorted by path,
    and returns a combined SHA256 hash of their content. Ignores translations,
    metadata, and other non-AL artifacts so that apps repackaged with different
    localizations produce the same hash.

    BC .app files are NavX packages (magic 0x5856414E). This script parses the
    NavX header to extract the ZIP content, following the same approach as
    BcContainerHelper's Extract-AppFileToFolder. Handles regular apps and
    Ready-to-Run apps (which embed a nested .app inside the ZIP).
    Runtime packages (compiled bytecode with no AL source) return $null.

.PARAMETER AppFile
    Path to the .app file.

.OUTPUTS
    String — the hex SHA256 hash, or $null if the app contains no .al files
    (including runtime packages).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AppFile
)

Add-Type -AssemblyName System.IO.Compression

function Get-AlContentHashFromZip([System.IO.Compression.ZipArchive] $zip) {
    $alEntries = $zip.Entries |
        Where-Object { $_.FullName -like '*.al' } |
        Sort-Object FullName

    if (-not $alEntries) { return $null }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($entry in $alEntries) {
            $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($entry.FullName)
            $sha.TransformBlock($pathBytes, 0, $pathBytes.Length, $null, 0) | Out-Null

            $entryStream = $entry.Open()
            try {
                $entryMs = [System.IO.MemoryStream]::new()
                $entryStream.CopyTo($entryMs)
                $contentBytes = $entryMs.ToArray()
                $sha.TransformBlock($contentBytes, 0, $contentBytes.Length, $null, 0) | Out-Null
            }
            finally {
                $entryStream.Dispose()
            }
        }

        $sha.TransformFinalBlock([byte[]]::new(0), 0, 0) | Out-Null
        return [BitConverter]::ToString($sha.Hash).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

# NavX header parsing mirrors BcContainerHelper's Extract-AppFileToFolder:
# https://github.com/microsoft/navcontainerhelper/blob/master/AppHandling/Extract-AppFileToFolder.ps1
function Get-ZipContentFromNavx([string] $filePath) {
    $fileStream = [System.IO.File]::OpenRead($filePath)
    try {
        $reader = [System.IO.BinaryReader]::new($fileStream)
        $magicNumber1    = $reader.ReadUInt32()
        $metadataSize    = $reader.ReadUInt32()
        $metadataVersion = $reader.ReadUInt32()
        $packageId       = [Guid]::new($reader.ReadBytes(16))
        $contentLength   = $reader.ReadInt64()
        $magicNumber2    = $reader.ReadUInt32()

        if ($magicNumber1 -ne 0x5856414E -or
            $magicNumber2 -ne 0x5856414E -or
            $metadataVersion -gt 2 -or
            $fileStream.Position + $contentLength -gt $fileStream.Length) {
            return $null
        }

        $content = $reader.ReadBytes($contentLength)

        # Runtime packages (compiled bytecode) have no AL source
        if ([BitConverter]::ToInt64($content, 0) -eq 72057595132988974) {
            return $null
        }

        return $content
    }
    finally {
        $fileStream.Dispose()
    }
}

# Parse NavX header and extract ZIP content bytes
$content = Get-ZipContentFromNavx $AppFile
if ($null -eq $content) { return $null }

$ms = [System.IO.MemoryStream]::new($content)
$zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Read)
try {
    # Ready-to-Run apps embed a nested .app file inside the ZIP
    $r2rManifest = $zip.Entries | Where-Object { $_.FullName -eq 'readytorunappmanifest.json' }
    if ($r2rManifest) {
        $manifestStream = $r2rManifest.Open()
        try {
            $manifestReader = [System.IO.StreamReader]::new($manifestStream)
            $manifestJson = $manifestReader.ReadToEnd() | ConvertFrom-Json
            $embeddedAppName = $manifestJson.EmbeddedAppFileName
        }
        finally {
            $manifestStream.Dispose()
        }

        $embeddedEntry = $zip.Entries | Where-Object { $_.FullName -eq $embeddedAppName }
        if (-not $embeddedEntry) { return $null }

        # Extract embedded .app to temp, recurse
        $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + '.app')
        try {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($embeddedEntry, $tmpFile)

            $innerContent = Get-ZipContentFromNavx $tmpFile
            if ($null -eq $innerContent) { return $null }

            $innerMs = [System.IO.MemoryStream]::new($innerContent)
            $innerZip = [System.IO.Compression.ZipArchive]::new($innerMs, [System.IO.Compression.ZipArchiveMode]::Read)
            try {
                return Get-AlContentHashFromZip $innerZip
            }
            finally {
                $innerZip.Dispose()
                $innerMs.Dispose()
            }
        }
        finally {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }

    return Get-AlContentHashFromZip $zip
}
finally {
    $zip.Dispose()
    $ms.Dispose()
}
