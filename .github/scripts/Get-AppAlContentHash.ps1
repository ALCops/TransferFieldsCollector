<#
.SYNOPSIS
    Computes a SHA256 hash of only the .al file contents inside a BC .app package.

.DESCRIPTION
    Opens an .app file as a zip archive, reads all .al entries sorted by path,
    and returns a combined SHA256 hash of their content. Ignores translations,
    metadata, and other non-AL artifacts so that apps repackaged with different
    localizations produce the same hash.

    BC .app files are NavX packages with a binary header (starting with "NAVX")
    prepended before the ZIP content. This script handles the offset automatically.

.PARAMETER AppFile
    Path to the .app file.

.OUTPUTS
    String — the hex SHA256 hash, or $null if the app contains no .al files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AppFile
)

Add-Type -AssemblyName System.IO.Compression

# BC .app files are NavX packages: a binary header followed by a standard ZIP archive.
# .NET's ZipArchive cannot handle prepended data (offsets are relative to stream start),
# so we locate the ZIP signature and create a stream starting from there.
$fileBytes = [System.IO.File]::ReadAllBytes($AppFile)

$zipStart = -1
$limit = [Math]::Min($fileBytes.Length - 4, 4096)
for ($i = 0; $i -le $limit; $i++) {
    if ($fileBytes[$i] -eq 0x50 -and $fileBytes[$i + 1] -eq 0x4B -and
        $fileBytes[$i + 2] -eq 0x03 -and $fileBytes[$i + 3] -eq 0x04) {
        $zipStart = $i
        break
    }
}

if ($zipStart -lt 0) { return $null }

$ms = [System.IO.MemoryStream]::new($fileBytes, $zipStart, $fileBytes.Length - $zipStart)
$zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Read)
try {
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
finally {
    $zip.Dispose()
    $ms.Dispose()
}
