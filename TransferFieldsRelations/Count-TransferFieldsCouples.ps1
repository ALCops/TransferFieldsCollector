<#
.SYNOPSIS
    Counts unique TransferFields couples across all versioned JSON files.

.DESCRIPTION
    Reads all TransferFieldsRelations-*.json files and produces two counts:

    - Total   : Unique directional pairs (A -> B and B -> A count as two).
    - Distinct: Direction-agnostic pairs (A -> B and B -> A count as one).

.PARAMETER JsonFolder
    Path to the folder containing TransferFieldsRelations-*.json files.

.EXAMPLE
    .\Count-TransferFieldsCouples.ps1 -JsonFolder "..\TransferFields"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $JsonFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate input folder
if (-not (Test-Path -LiteralPath $JsonFolder -PathType Container)) {
    throw "JSON folder not found: $JsonFolder"
}

# Find all JSON files matching the pattern
$jsonFiles = Get-ChildItem -Path $JsonFolder -Filter "TransferFieldsRelations-*.json" -File |
    Sort-Object Name

if ($jsonFiles.Count -eq 0) {
    throw "No TransferFieldsRelations-*.json files found in: $JsonFolder"
}

Write-Host "Found $($jsonFiles.Count) JSON file(s) to process."

# $directionalSet  : key = "Source|Target"          (A->B != B->A)
# $bidirectionalSet: key = sorted canonical pair     (A->B == B->A)
$directionalSet   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$bidirectionalSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

foreach ($jsonFile in $jsonFiles) {
    $jsonText = Get-Content -LiteralPath $jsonFile.FullName -Raw -Encoding UTF8
    $data = $jsonText | ConvertFrom-Json

    if ($null -eq $data -or $null -eq $data.relations) {
        Write-Warning "  Skipping $($jsonFile.Name) - no relations found"
        continue
    }

    foreach ($relation in $data.relations) {
        if ([string]::IsNullOrWhiteSpace($relation.Source) -or [string]::IsNullOrWhiteSpace($relation.Target)) {
            continue
        }

        $source = $relation.Source
        $target = $relation.Target

        # Directional key: order matters
        $directionalKey = "$source|$target"
        $null = $directionalSet.Add($directionalKey)

        # Bidirectional key: sort the two names so A->B and B->A share a key
        if ([string]::CompareOrdinal($source, $target) -le 0) {
            $biKey = "$source|$target"
        }
        else {
            $biKey = "$target|$source"
        }
        $null = $bidirectionalSet.Add($biKey)
    }
}

$total    = $directionalSet.Count
$distinct = $bidirectionalSet.Count
$bidirPairs = $total - $distinct

Write-Host ""
Write-Host "Results"
Write-Host "-------"
Write-Host "Total unique couples (directional) : $total"
Write-Host "Distinct couples (direction-agnostic): $distinct"
Write-Host ""
Write-Host "Bidirectional pairs (A->B and B<-A both exist): $bidirPairs"

if ($bidirPairs -gt 0) {
    Write-Host ""
    Write-Host "Bidirectional couples:"
    foreach ($key in ($bidirectionalSet | Sort-Object)) {
        $parts = $key -split '\|', 2
        $a = $parts[0]
        $b = $parts[1]
        # Only list if both directions were seen
        if ($directionalSet.Contains("$a|$b") -and $directionalSet.Contains("$b|$a")) {
            Write-Host "  $a  <->  $b"
        }
    }
}
