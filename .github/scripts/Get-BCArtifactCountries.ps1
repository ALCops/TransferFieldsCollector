<#
.SYNOPSIS
    Retrieves available BC artifact countries from the CDN index.

.DESCRIPTION
    Downloads the countries index from the BC artifact CDN and optionally filters
    by version. When a version is specified, each country's artifact index is checked
    to verify artifacts exist for that version prefix, and the latest matching
    artifact URL is included in the output.

    This script has no dependency on BcContainerHelper.

.PARAMETER Type
    Artifact type: Sandbox or OnPrem. Default: Sandbox.

.PARAMETER Version
    Optional BC version prefix (e.g., "28.2"). When specified, only countries
    with artifacts matching this prefix are returned, along with their artifact URLs.

.PARAMETER ExcludeEntries
    Index entries to filter out (not real localizations).
    Default: platform, base, core.

.OUTPUTS
    JSON string. Without -Version: array of country codes.
    With -Version: array of objects with country, version, and url properties.

.EXAMPLE
    $countries = & ./Get-BCArtifactCountries.ps1 -Type Sandbox | ConvertFrom-Json

.EXAMPLE
    $matrix = & ./Get-BCArtifactCountries.ps1 -Type Sandbox -Version "28.2" | ConvertFrom-Json
#>

[CmdletBinding()]
param(
    [ValidateSet('Sandbox', 'OnPrem')]
    [string]$Type = 'Sandbox',

    [string]$Version,

    [string[]]$ExcludeEntries = @('platform', 'base', 'core')
)

$ErrorActionPreference = 'Stop'

$CdnUrls = @(
    'https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net',
    'https://bcartifacts.azureedge.net'
)

$typePath = $Type.ToLowerInvariant()

function Invoke-CdnRequest {
    param(
        [string]$RelativePath,
        [int]$TimeoutSec = 30
    )

    $lastError = $null
    foreach ($cdnBase in $script:CdnUrls) {
        $url = "$cdnBase/$RelativePath"
        try {
            return Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSec
        }
        catch {
            $lastError = $_
            Write-Host "  CDN request failed for $url : $($_.Exception.Message)"
        }
    }
    throw "All CDN endpoints failed for $RelativePath. Last error: $lastError"
}

Write-Host "Fetching countries index for type '$typePath'..."
$allEntries = Invoke-CdnRequest -RelativePath "$typePath/indexes/countries.json"

$countries = $allEntries | Where-Object { $_ -notin $ExcludeEntries } | Sort-Object
Write-Host "Found $($countries.Count) countries (after filtering $($ExcludeEntries -join ', '))"

if (-not $Version) {
    $countries | ConvertTo-Json -Compress
    return
}

# Ensure version prefix ends with a dot to prevent "20.0" matching "20.01.x"
$versionPrefix = $Version.TrimEnd('.') + '.'
Write-Host "Filtering countries for version prefix '$versionPrefix'..."

$matrixItems = $countries | ForEach-Object -Parallel {
    $country = $_
    $cdnUrls = $using:CdnUrls
    $typePath = $using:typePath
    $versionPrefix = $using:versionPrefix
    $version = $using:Version

    $lastError = $null
    $countryArtifacts = $null

    foreach ($cdnBase in $cdnUrls) {
        $url = "$cdnBase/$typePath/indexes/$country.json"
        try {
            $countryArtifacts = Invoke-RestMethod -Uri $url -TimeoutSec 15
            break
        }
        catch {
            $lastError = $_
        }
    }

    if (-not $countryArtifacts) {
        Write-Host "  WARNING: Failed to fetch index for '$country': $lastError"
        return
    }

    $matching = $countryArtifacts | Where-Object { $_.Version -like "$versionPrefix*" }
    if (-not $matching) {
        return
    }

    $latest = $matching | Sort-Object { [System.Version]$_.Version } | Select-Object -Last 1
    $artifactUrl = "$($cdnUrls[0])/$typePath/$($latest.Version)/$country"

    [PSCustomObject]@{
        country = $country
        version = $version
        url     = $artifactUrl
    }
} -ThrottleLimit 10

$matrixItems = @($matrixItems | Where-Object { $_ })

Write-Host "Found $($matrixItems.Count) countries with artifacts for version prefix '$versionPrefix'"

if ($matrixItems.Count -eq 0) {
    '[]'
}
elseif ($matrixItems.Count -eq 1) {
    ConvertTo-Json -InputObject @($matrixItems) -Compress -Depth 5
}
else {
    $matrixItems | ConvertTo-Json -Compress -Depth 5
}
