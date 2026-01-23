<#
.SYNOPSIS
    Merges multiple TransferFieldsRelations JSON files with deduplication.

.DESCRIPTION
    Reads all JSON files from a folder, deduplicates relations by composite key
    (Source|SourceNamespace|Target|TargetNamespace), and merges FoundInExtension arrays.

.PARAMETER InputFolder
    Folder containing TransferFieldsRelations JSON files to merge.

.PARAMETER OutputPath
    Path where the merged JSON file will be written.

.OUTPUTS
    PSCustomObject with properties:
    - Success: Boolean indicating if merge produced results
    - OutputFile: Path to the merged JSON file (if any)
    - RelationCount: Number of unique relations after merge
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InputFolder,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

if (-not (Test-Path $InputFolder)) {
    Write-Host "Input folder does not exist: $InputFolder"
    return [PSCustomObject]@{
        Success       = $false
        OutputFile    = $null
        RelationCount = 0
    }
}

$jsonFiles = Get-ChildItem -Path $InputFolder -Filter "*.json" -ErrorAction SilentlyContinue

if (-not $jsonFiles -or $jsonFiles.Count -eq 0) {
    Write-Host "No JSON files found in: $InputFolder"
    return [PSCustomObject]@{
        Success       = $false
        OutputFile    = $null
        RelationCount = 0
    }
}

Write-Host "Merging $($jsonFiles.Count) JSON files..."

# Use a hashtable for deduplication based on composite key
# Key: "Source|SourceNamespace|Target|TargetNamespace"
# Value: The relation object with merged FoundInExtension list
$relationsMap = @{}

foreach ($jsonFile in $jsonFiles) {
    Write-Host "  Processing: $($jsonFile.Name)"
    $jsonContent = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json

    foreach ($relation in $jsonContent) {
        # Create composite key
        $key = "$($relation.Source)|$($relation.SourceNamespace)|$($relation.Target)|$($relation.TargetNamespace)"

        if ($relationsMap.ContainsKey($key)) {
            # Merge FoundInExtension arrays
            $existingRelation = $relationsMap[$key]
            foreach ($extension in $relation.FoundInExtension) {
                # Check if this extension already exists (by AppId)
                $existingExtension = $existingRelation.FoundInExtension | Where-Object { $_.AppId -eq $extension.AppId }
                if ($existingExtension) {
                    # Merge FoundInObjects lists
                    foreach ($obj in $extension.FoundInObjects) {
                        $existingObj = $existingExtension.FoundInObjects |
                        Where-Object { $_.FoundInObjectQualified -eq $obj.FoundInObjectQualified -and $_.FoundInMethod -eq $obj.FoundInMethod }
                        if (-not $existingObj) {
                            $existingExtension.FoundInObjects.Add($obj)
                        }
                    }
                }
                else {
                    # Add new extension - convert FoundInObjects to list for future merges
                    $extensionCopy = $extension | ConvertTo-Json -Depth 100 | ConvertFrom-Json
                    $objectsList = [System.Collections.Generic.List[object]]::new()
                    foreach ($obj in $extensionCopy.FoundInObjects) {
                        $objectsList.Add($obj)
                    }
                    $extensionCopy.FoundInObjects = $objectsList
                    $existingRelation.FoundInExtension.Add($extensionCopy)
                }
            }
        }
        else {
            # Add new relation - convert arrays to lists for future merges
            $relationCopy = $relation | ConvertTo-Json -Depth 100 | ConvertFrom-Json
            
            # Convert FoundInExtension to list
            $extensionsList = [System.Collections.Generic.List[object]]::new()
            foreach ($ext in $relationCopy.FoundInExtension) {
                # Convert FoundInObjects to list
                $objectsList = [System.Collections.Generic.List[object]]::new()
                foreach ($obj in $ext.FoundInObjects) {
                    $objectsList.Add($obj)
                }
                $ext.FoundInObjects = $objectsList
                $extensionsList.Add($ext)
            }
            $relationCopy.FoundInExtension = $extensionsList
            
            $relationsMap[$key] = $relationCopy
        }
    }
}

# Convert hashtable values to array
$mergedRelations = @($relationsMap.Values)
$relationCount = $mergedRelations.Count

Write-Host "Merged into $relationCount unique relations"

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Write output (just the relations array, metadata added by New-AnalysisResult.ps1)
$mergedRelations | ConvertTo-Json -Depth 100 | Set-Content -Path $OutputPath

Write-Host "Merged output written to: $OutputPath"

return [PSCustomObject]@{
    Success       = $true
    OutputFile    = $OutputPath
    RelationCount = $relationCount
}
