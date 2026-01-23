<#
.SYNOPSIS
    Wraps merged relations with version/country/timestamp metadata.

.DESCRIPTION
    Takes a merged relations JSON file and wraps it with metadata including
    BC version, country code, and generation timestamp.

.PARAMETER RelationsFile
    Path to the merged relations JSON file.

.PARAMETER Version
    BC version string (e.g., "27.2").

.PARAMETER Country
    Country/localization code (e.g., "w1", "be", "nl").

.PARAMETER OutputPath
    Path where the final result JSON file will be written.

.OUTPUTS
    PSCustomObject with properties:
    - Success: Boolean indicating if the result was created
    - OutputFile: Path to the final JSON file
    - RelationCount: Number of relations in the result
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RelationsFile,

    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$Country,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

if (-not (Test-Path $RelationsFile)) {
    Write-Host "Relations file does not exist: $RelationsFile"
    return [PSCustomObject]@{
        Success       = $false
        OutputFile    = $null
        RelationCount = 0
    }
}

Write-Host "Creating analysis result for v$Version $Country..."

# Read merged relations
$relationsJson = Get-Content $RelationsFile -Raw | ConvertFrom-Json
$relations = @($relationsJson)
$relationCount = $relations.Count

# Create wrapper with metadata
$result = [PSCustomObject]@{
    version     = $Version
    country     = $Country
    generatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    relations   = [array]$relations
}

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Write final JSON
$result | ConvertTo-Json -Depth 100 | Set-Content -Path $OutputPath

Write-Host "Result written to: $OutputPath"
Write-Host "  Version: $Version"
Write-Host "  Country: $Country"
Write-Host "  Relations: $relationCount"

return [PSCustomObject]@{
    Success       = $true
    OutputFile    = $OutputPath
    RelationCount = $relationCount
}
