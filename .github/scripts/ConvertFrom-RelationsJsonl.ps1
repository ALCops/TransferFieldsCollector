<#
.SYNOPSIS
    Aggregates relations.jsonl files into a grouped JSON structure.

.DESCRIPTION
    Reads all relations.jsonl files from a folder, groups them by Source/Target table
    pairs, and outputs a structured JSON with extension and object information.

.PARAMETER JsonlRoot
    Root folder containing relations.jsonl files (searched recursively).

.PARAMETER OutputPath
    Path where the aggregated JSON file will be written.

.OUTPUTS
    PSCustomObject with properties:
    - Success: Boolean indicating if aggregation produced results
    - OutputFile: Path to the generated JSON file (if any)
    - RelationCount: Number of unique relations found
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$JsonlRoot,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

if (-not (Test-Path $JsonlRoot)) {
    Write-Host "JSONL root folder does not exist: $JsonlRoot"
    return [PSCustomObject]@{
        Success       = $false
        OutputFile    = $null
        RelationCount = 0
    }
}

# Read all JSONL files
$jsonlFiles = Get-ChildItem $JsonlRoot -Recurse -Filter relations.jsonl -ErrorAction SilentlyContinue

if (-not $jsonlFiles -or $jsonlFiles.Count -eq 0) {
    Write-Host "No relations.jsonl files found in: $JsonlRoot"
    return [PSCustomObject]@{
        Success       = $false
        OutputFile    = $null
        RelationCount = 0
    }
}

Write-Host "Reading $($jsonlFiles.Count) JSONL file(s)..."

$rows = $jsonlFiles |
Get-Content |
ForEach-Object { $_ | ConvertFrom-Json } |
ForEach-Object {
    # Flatten the nested structure: relation properties + extension properties
    [PSCustomObject]@{
        source                 = $_.relation.source
        sourceNamespace        = $_.relation.sourceNamespace
        sourceObjectId         = $_.relation.sourceObjectId
        target                 = $_.relation.target
        targetNamespace        = $_.relation.targetNamespace
        targetObjectId         = $_.relation.targetObjectId
        foundInObjectQualified = $_.relation.foundInObjectQualified
        foundInMethod          = $_.relation.foundInMethod
        appId                  = $_.appId
        extensionName          = $_.extensionName
        publisher              = $_.publisher
        version                = $_.version
    }
} |
Where-Object { $_.Source -and $_.Target }  # Filter out any null/empty source-target pairs

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "No relations found in JSONL files"
    return [PSCustomObject]@{
        Success       = $false
        OutputFile    = $null
        RelationCount = 0
    }
}

Write-Host "Aggregating $($rows.Count) relation rows..."

# Group by Source/Target table pairs
$grouped = $rows |
Group-Object Source, SourceNamespace, Target, TargetNamespace |
ForEach-Object {
    $g = $_.Group
    [PSCustomObject]@{
        source           = $g[0].Source
        sourceNamespace  = $g[0].SourceNamespace
        sourceObjectId   = $g[0].SourceObjectId
        target           = $g[0].Target
        targetNamespace  = $g[0].TargetNamespace
        targetObjectId   = $g[0].TargetObjectId
        foundInExtension = $g |
        Group-Object AppId, ExtensionName, Publisher, Version |
        ForEach-Object {
            [PSCustomObject]@{
                appId          = $_.Group[0].AppId
                name           = $_.Group[0].ExtensionName
                publisher      = $_.Group[0].Publisher
                version        = $_.Group[0].Version
                foundInObjects = $_.Group |
                Select-Object FoundInObjectQualified, FoundInMethod -Unique
            }
        }
    }
}

$relationCount = @($grouped).Count
Write-Host "Grouped into $relationCount unique relations"

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Write output
$grouped | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath

Write-Host "Output written to: $OutputPath"

return [PSCustomObject]@{
    Success       = $true
    OutputFile    = $OutputPath
    RelationCount = $relationCount
}
