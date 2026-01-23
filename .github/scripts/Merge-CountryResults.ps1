<#
.SYNOPSIS
    Merges TransferFieldsRelations results from multiple countries into one aggregated file.

.DESCRIPTION
    Reads all per-country JSON result files, combines them, and outputs an aggregated
    result with country information embedded in each FoundInExtensions entry.

.PARAMETER InputFolder
    Folder containing per-country TransferFieldsRelations JSON files (searched recursively).

.PARAMETER Version
    BC version string for the aggregated result.

.PARAMETER OutputPath
    Path where the aggregated JSON file will be written.

.OUTPUTS
    PSCustomObject with properties:
    - Success: Boolean indicating if aggregation produced results
    - OutputFile: Path to the aggregated JSON file
    - Countries: Array of country codes included
    - RelationCount: Number of unique relations in the result
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InputFolder,

    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

if (-not (Test-Path $InputFolder)) {
    Write-Host "Input folder does not exist: $InputFolder"
    return [PSCustomObject]@{
        Success       = $false
        OutputFile    = $null
        Countries     = @()
        RelationCount = 0
    }
}

Write-Host "Looking for results in: $InputFolder"

$jsonFiles = Get-ChildItem -Path $InputFolder -Filter "*.json" -Recurse
Write-Host "Found $($jsonFiles.Count) JSON files"

if (-not $jsonFiles -or $jsonFiles.Count -eq 0) {
    return [PSCustomObject]@{
        Success       = $false
        OutputFile    = $null
        Countries     = @()
        RelationCount = 0
    }
}

# Dictionary to hold merged relations keyed by (Source, SourceNamespace, Target, TargetNamespace)
$relationsMap = @{}
$allCountries = @()

foreach ($jsonFile in $jsonFiles) {
    Write-Host "Processing: $($jsonFile.FullName)"
    $content = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json
    $country = $content.country

    if (-not $country) {
        Write-Warning "  No country field found, skipping file"
        continue
    }

    $allCountries += $country

    $relations = @($content.relations)
    if ($relations.Count -eq 0) {
        Write-Host "  No relations found"
        continue
    }

    foreach ($relation in $relations) {
        # Create composite key for the relation
        $relationKey = "$($relation.Source)|$($relation.SourceNamespace)|$($relation.Target)|$($relation.TargetNamespace)"

        if (-not $relationsMap.ContainsKey($relationKey)) {
            # Initialize new relation entry
            $relationsMap[$relationKey] = @{
                source          = $relation.Source
                sourceNamespace = $relation.SourceNamespace
                target          = $relation.Target
                targetNamespace = $relation.TargetNamespace
                extensionsMap   = @{} # Keyed by AppId
            }
        }

        $relationEntry = $relationsMap[$relationKey]

        # Process each FoundInExtension
        $extensions = $relation.FoundInExtension
        if (-not $extensions) { $extensions = $relation.FoundInExtensions }
        if (-not $extensions) { continue }

        foreach ($ext in $extensions) {
            $extKey = "$($ext.AppId)"

            if (-not $relationEntry.ExtensionsMap.ContainsKey($extKey)) {
                $relationEntry.ExtensionsMap[$extKey] = @{
                    appId          = $ext.AppId
                    name           = $ext.Name
                    publisher      = $ext.Publisher
                    countries      = @()
                    foundInObjects = @()
                }
            }

            $extEntry = $relationEntry.ExtensionsMap[$extKey]

            # Add country if not already present
            if ($extEntry.Countries -notcontains $country) {
                $extEntry.Countries += $country
            }

            # Concatenate FoundInObjects (no deduplication per user requirement)
            if ($ext.FoundInObjects) {
                $extEntry.FoundInObjects += $ext.FoundInObjects
            }
        }
    }
}

# Convert maps to final array structure
$mergedRelations = @()

foreach ($relationKey in $relationsMap.Keys) {
    $rel = $relationsMap[$relationKey]

    $extensions = @()
    foreach ($extKey in $rel.ExtensionsMap.Keys) {
        $ext = $rel.ExtensionsMap[$extKey]
        $extensions += [PSCustomObject]@{
            appId          = $ext.AppId
            name           = $ext.Name
            publisher      = $ext.Publisher
            countries      = ($ext.Countries | Sort-Object)
            foundInObjects = $ext.FoundInObjects
        }
    }

    $mergedRelations += [PSCustomObject]@{
        source            = $rel.Source
        sourceNamespace   = $rel.SourceNamespace
        target            = $rel.Target
        targetNamespace   = $rel.TargetNamespace
        foundInExtensions = $extensions
    }
}

# Sort relations for consistent output
$mergedRelations = $mergedRelations | Sort-Object -Property Source, SourceNamespace, Target, TargetNamespace

# Get unique countries for reporting
$uniqueCountries = $allCountries | Sort-Object -Unique

# Create aggregated result (no top-level countries array - country info is in extensions)
$aggregated = @{
    version        = $Version
    generatedAt    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    totalRelations = $mergedRelations.Count
    relations      = $mergedRelations
}

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$aggregated | ConvertTo-Json -Depth 100 | Set-Content -Path $OutputPath

Write-Host "Aggregated results written to: $OutputPath"
Write-Host "Total unique relations: $($mergedRelations.Count)"
Write-Host "Countries included: $($uniqueCountries -join ', ')"

return [PSCustomObject]@{
    Success       = $true
    OutputFile    = $OutputPath
    Countries     = $uniqueCountries
    RelationCount = $mergedRelations.Count
}