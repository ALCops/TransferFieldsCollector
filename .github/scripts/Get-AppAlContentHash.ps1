<#
.SYNOPSIS
    Computes a SHA256 hash of only the .al file contents inside a BC .app package.

.DESCRIPTION
    Opens an .app file as a zip archive, reads all .al entries sorted by path,
    and returns a combined SHA256 hash of their content. Ignores translations,
    metadata, and other non-AL artifacts so that apps repackaged with different
    localizations produce the same hash.

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

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::OpenRead($AppFile)
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

            $stream = $entry.Open()
            try {
                $ms = [System.IO.MemoryStream]::new()
                $stream.CopyTo($ms)
                $contentBytes = $ms.ToArray()
                $sha.TransformBlock($contentBytes, 0, $contentBytes.Length, $null, 0) | Out-Null
            }
            finally {
                $stream.Dispose()
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
}
