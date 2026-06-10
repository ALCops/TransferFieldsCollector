<#
.SYNOPSIS
    Downloads BC platform artifacts and extracts only the .app files needed for compilation.

.DESCRIPTION
    Uses BcContainerHelper to download platform artifacts for a given BC version,
    then extracts only the .app files (from the Applications folder and System.app)
    into a flat output directory suitable for use as the AL compiler's /packagecachepath.

.PARAMETER Version
    BC version to download platform for (e.g., "28.2").

.PARAMETER OutputPath
    Directory to write extracted .app files to.

.PARAMETER Type
    Artifact type: Sandbox or OnPrem. Default: Sandbox.

.OUTPUTS
    PSCustomObject with:
    - AppCount: Number of .app files extracted
    - TotalSizeMB: Total size of extracted .app files in MB
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [ValidateSet('Sandbox', 'OnPrem')]
    [string]$Type = 'Sandbox'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -Name BcContainerHelper)) {
    Import-Module BcContainerHelper -Force -DisableNameChecking
}

# Resolve artifact URL for W1 (world) localization
Write-Host "Resolving artifact URL for $Type v$Version (country: w1)..."
$artifactUrl = Get-BCArtifactUrl -Type $Type -Country w1 -Version $Version -Select Latest

if (-not $artifactUrl) {
    throw "No artifact found for $Type v$Version"
}

Write-Host "Artifact URL: $artifactUrl"

# Download both W1 and platform artifacts (BcContainerHelper handles platform URL resolution,
# including manifest.json platformUrl overrides for older versions)
Write-Host "Downloading artifacts (W1 + platform)..."
$artifactPaths = Download-Artifacts -artifactUrl $artifactUrl -includePlatform
$w1CountryPath = $artifactPaths[0]
$platformPath = $artifactPaths[1]
Write-Host "W1 country artifact: $w1CountryPath"
Write-Host "Platform extracted to: $platformPath"

# Create output directory
if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Collect .app files from the Applications folder (case-insensitive: Applications or applications)
$applicationsFolder = Join-Path $platformPath '?pplications' -Resolve -ErrorAction SilentlyContinue
if ($applicationsFolder) {
    $appFiles = Get-ChildItem -Path $applicationsFolder -Recurse -Filter "*.app" -File
    Write-Host "Found $($appFiles.Count) .app files in $applicationsFolder"
    foreach ($file in $appFiles) {
        Copy-Item -Path $file.FullName -Destination (Join-Path $OutputPath $file.Name) -Force
    }
}
else {
    Write-Warning "Applications folder not found in platform artifacts at $platformPath"
}

# Collect System.app from ModernDev folder
$systemApp = Get-ChildItem -Path $platformPath -Recurse -Filter "System.app" -File |
    Where-Object { $_.DirectoryName -like "*AL Development Environment*" } |
    Select-Object -First 1

if ($systemApp) {
    Write-Host "Found System.app at $($systemApp.FullName)"
    Copy-Item -Path $systemApp.FullName -Destination (Join-Path $OutputPath "System.app") -Force
}
else {
    Write-Warning "System.app not found in platform artifacts"
}

# Compute SHA256 fingerprints for W1 Extension .app files
$fingerprintFile = Join-Path $OutputPath "w1-app-fingerprints.json"
$w1ExtensionsFolder = Join-Path $w1CountryPath "Extensions"

if (Test-Path $w1ExtensionsFolder) {
    $w1AppFiles = Get-ChildItem -Path $w1ExtensionsFolder -Filter "*.app" -Recurse -File
    Write-Host "Computing fingerprints for $($w1AppFiles.Count) W1 Extension .app files..."

    $fingerprints = [ordered]@{}
    foreach ($w1App in $w1AppFiles) {
        $hash = (Get-FileHash -Path $w1App.FullName -Algorithm SHA256).Hash
        $fingerprints[$hash] = $w1App.Name
    }

    [ordered]@{
        appCount     = $fingerprints.Count
        fingerprints = $fingerprints
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $fingerprintFile

    Write-Host "W1 fingerprint manifest: $fingerprintFile ($($fingerprints.Count) apps)"
}
else {
    Write-Warning "W1 Extensions folder not found at $w1ExtensionsFolder - no fingerprints generated"
    [ordered]@{
        appCount     = 0
        fingerprints = @{}
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $fingerprintFile
}

# Report results
$outputFiles = Get-ChildItem -Path $OutputPath -Filter "*.app" -File
$totalSizeMB = [math]::Round(($outputFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 1)

Write-Host ""
Write-Host "Platform apps extracted to: $OutputPath"
Write-Host "  Total .app files: $($outputFiles.Count)"
Write-Host "  Total size: ${totalSizeMB} MB"

[PSCustomObject]@{
    AppCount    = $outputFiles.Count
    TotalSizeMB = $totalSizeMB
}
