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

# Deterministic namespace-casing canonicalization (see NamespaceCasing.ps1).
. "$PSScriptRoot/NamespaceCasing.ps1"

# Dictionary to hold merged relations keyed by (Source, SourceNamespace, Target, TargetNamespace)
$relationsMap = @{}
$allCountries = @()

# First pass: read every per-country file once and build the casing registry. The 'w1'
# localization leads: if a namespace casing was seen in w1, it wins; otherwise the
# ordinally-smallest casing is used. Both rules are order-independent, so the merged output
# is stable across workflow runs regardless of artifact download/processing order.
$countryContents = [System.Collections.Generic.List[object]]::new()
$casingRegistry = New-NamespaceCasingRegistry

foreach ($jsonFile in $jsonFiles) {
    Write-Host "Reading: $($jsonFile.FullName)"
    $content = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json
    $country = $content.country

    if (-not $country) {
        Write-Warning "  No country field found, skipping file"
        continue
    }

    $countryContents.Add([PSCustomObject]@{ Country = $country; Content = $content })

    $isW1 = ($country -ieq 'w1')
    foreach ($relation in @($content.relations)) {
        Add-NamespaceObservation -Registry $casingRegistry -Namespace $relation.SourceNamespace -IsW1:$isW1
        Add-NamespaceObservation -Registry $casingRegistry -Namespace $relation.TargetNamespace -IsW1:$isW1
    }
}

$nsKeysByLen = Get-NamespaceKeysByLengthDesc -Registry $casingRegistry

# Build a registry of fully-qualified found-in object names so their casing is also
# canonicalized deterministically. A found-in object's namespace is frequently NOT a table
# Source/Target namespace, so it is absent from the namespace registry above; without this
# its casing would still flip-flop with artifact download/processing order.
$qualifiedRegistry = New-NamespaceCasingRegistry
foreach ($entry in $countryContents) {
    $isW1 = ($entry.Country -ieq 'w1')
    foreach ($relation in @($entry.Content.relations)) {
        $exts = $relation.FoundInExtension
        if (-not $exts) { $exts = $relation.FoundInExtensions }
        foreach ($ext in @($exts)) {
            if (-not $ext) { continue }
            foreach ($obj in @($ext.FoundInObjects)) {
                if ($obj -and $obj.foundInObjectQualified) {
                    Add-QualifiedObservation -NamespaceRegistry $casingRegistry -QualifiedRegistry $qualifiedRegistry -Qualified $obj.foundInObjectQualified -NamespaceKeysByLengthDesc $nsKeysByLen -IsW1:$isW1
                }
            }
        }
    }
}

# Second pass: canonicalize casings, then merge.
foreach ($entry in $countryContents) {
    $country = $entry.Country
    $content = $entry.Content
    Write-Host "Processing: $country"

    $allCountries += $country

    $relations = @($content.relations)
    if ($relations.Count -eq 0) {
        Write-Host "  No relations found"
        continue
    }

    foreach ($relation in $relations) {
        # Canonicalize namespace casing deterministically before keying and merging.
        if ($relation.SourceNamespace) {
            $relation.SourceNamespace = Resolve-CanonicalNamespace -Registry $casingRegistry -Namespace $relation.SourceNamespace
        }
        if ($relation.TargetNamespace) {
            $relation.TargetNamespace = Resolve-CanonicalNamespace -Registry $casingRegistry -Namespace $relation.TargetNamespace
        }

        # Create composite key for the relation
        $relationKey = "$($relation.Source)|$($relation.SourceNamespace)|$($relation.Target)|$($relation.TargetNamespace)"

        if (-not $relationsMap.ContainsKey($relationKey)) {
            # Initialize new relation entry
            $relationsMap[$relationKey] = @{
                source          = $relation.Source
                sourceNamespace = $relation.SourceNamespace
                sourceObjectId  = $relation.SourceObjectId
                target          = $relation.Target
                targetNamespace = $relation.TargetNamespace
                targetObjectId  = $relation.TargetObjectId
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
                foreach ($obj in @($ext.FoundInObjects)) {
                    if ($obj -and $obj.foundInObjectQualified) {
                        $obj.foundInObjectQualified = Resolve-CanonicalQualifiedNameStable -NamespaceRegistry $casingRegistry -QualifiedRegistry $qualifiedRegistry -Qualified $obj.foundInObjectQualified -NamespaceKeysByLengthDesc $nsKeysByLen
                    }
                }
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

        # Deduplicate and sort foundInObjects for consistent output
        $uniqueFoundInObjects = @()
        if ($ext.FoundInObjects) {
            $uniqueFoundInObjects = $ext.FoundInObjects |
            Group-Object -Property { "$($_.foundInObjectQualified)|$($_.foundInMethod)" } |
            ForEach-Object { $_.Group[0] } |
            Sort-Object -Property foundInObjectQualified, foundInMethod
        }

        $extensions += [PSCustomObject]@{
            appId          = $ext.AppId
            name           = $ext.Name
            publisher      = $ext.Publisher
            countries      = ($ext.Countries | Sort-Object)
            foundInObjects = @($uniqueFoundInObjects)
        }
    }

    # Sort extensions by appId for consistent output
    $extensions = $extensions | Sort-Object -Property appId

    $mergedRelations += [PSCustomObject]@{
        source            = $rel.Source
        sourceNamespace   = $rel.SourceNamespace
        sourceObjectId    = $rel.SourceObjectId
        target            = $rel.Target
        targetNamespace   = $rel.TargetNamespace
        targetObjectId    = $rel.TargetObjectId
        foundInExtensions = $extensions
    }
}

# Sort relations for consistent output
$mergedRelations = $mergedRelations | Sort-Object -Property Source, SourceNamespace, Target, TargetNamespace

# Get unique countries for reporting
$uniqueCountries = $allCountries | Sort-Object -Unique

# Create aggregated result (no top-level countries array - country info is in extensions)
# Use [ordered] to ensure consistent property order in JSON output
$aggregated = [ordered]@{
    version        = $Version
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