<#
.SYNOPSIS
    Discovers available BC artifact versions and returns them as an array.

.DESCRIPTION
    Iterates through BC versions starting from the specified major.minor,
    incrementing minor versions (x.0 through x.9) then jumping to next major.
    Stops when a new major version (x.0) returns no artifact.

.PARAMETER StartMajor
    The major version to start from (default: 16)

.PARAMETER StartMinor
    The minor version to start from (default: 0)

.EXAMPLE
    .\Get-ArtifactVersions.ps1 -StartMajor 20 -StartMinor 0
#>

param(
    [int]$StartMajor = 16,
    [int]$StartMinor = 0
)

# Ensure BcContainerHelper is available
if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
    Write-Host "Installing BcContainerHelper..."
    Install-Module BcContainerHelper -Force -AllowClobber
}
Import-Module BcContainerHelper -Force -DisableNameChecking

$currentMajor = $StartMajor
$currentMinor = $StartMinor
$versions = @()

Write-Host "Starting version discovery from $currentMajor.$currentMinor"

while ($true) {
    $version = "$currentMajor.$currentMinor"
    Write-Host "Checking version $version..." -NoNewline
    
    try {
        $url = Get-BCArtifactUrl -Type Sandbox -Country W1 -Version $version -Select Latest -ErrorAction SilentlyContinue
    }
    catch {
        $url = $null
    }
    
    if ($url) {
        Write-Host " Found" -ForegroundColor Green
        $versions += @{
            Version = $version
            Major   = $currentMajor
            Minor   = $currentMinor
            Url     = $url
        }
    }
    else {
        Write-Host " Not found" -ForegroundColor Yellow
    }
    
    # Move to next version
    if ($currentMinor -lt 9) {
        $currentMinor++
    }
    else {
        # Jump to next major
        $currentMajor++
        $currentMinor = 0
        
        # Check if the new major version exists
        $newMajorVersion = "$currentMajor.0"
        Write-Host "Checking new major version $newMajorVersion..." -NoNewline
        
        try {
            $majorUrl = Get-BCArtifactUrl -Type Sandbox -Country W1 -Version $newMajorVersion -Select Latest -ErrorAction SilentlyContinue
        }
        catch {
            $majorUrl = $null
        }
        
        if (-not $majorUrl) {
            Write-Host " Not found - stopping discovery" -ForegroundColor Red
            break
        }
        else {
            Write-Host " Found" -ForegroundColor Green
        }
    }
}

Write-Host "`nDiscovery complete. Found $($versions.Count) versions."

# Return versions
return $versions
