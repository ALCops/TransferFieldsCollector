<#
.SYNOPSIS
    Extracts a single .app file and runs the AL compiler with the TransferFields analyzer.

.DESCRIPTION
    This script extracts a BC .app file to a temporary folder, runs the AL compiler
    with the specified analyzer DLL, and returns the path to any generated JSONL files.

.PARAMETER AppFile
    Path to the .app file to analyze.

.PARAMETER AnalyzerDll
    Path to the TransferFields analyzer DLL.

.PARAMETER PlatformPath
    Path to the BC platform artifacts (for package cache).

.PARAMETER TempRoot
    Root folder for temporary extraction. Defaults to $env:RUNNER_TEMP or $env:TEMP.

.OUTPUTS
    PSCustomObject with properties:
    - Success: Boolean indicating if analysis completed
    - JsonlRoot: Path to folder containing relations.jsonl files (if any)
    - AppName: Name of the processed app file
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AppFile,

    [Parameter(Mandatory)]
    [string]$AnalyzerDll,

    [Parameter(Mandatory)]
    [string]$PlatformPath,

    [Parameter()]
    [string]$TempRoot = $env:RUNNER_TEMP ?? $env:TEMP
)

$appFileName = Split-Path $AppFile -Leaf
Write-Host "Processing: $appFileName"

# Create temp folder for extracted app
$extractFolder = Join-Path $TempRoot "extracted-$(New-Guid)"
New-Item -ItemType Directory -Path $extractFolder -Force | Out-Null

try {
    # Extract app file (NavX format: binary header + ZIP payload)
    Write-Host "  Extracting to $extractFolder..."
    $extractScript = Join-Path $PSScriptRoot "extract_navx_app.py"
    & python3 $extractScript $AppFile $extractFolder 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Extraction failed (exit code: $LASTEXITCODE), skipping..."
        return [PSCustomObject]@{
            Success   = $false
            JsonlRoot = $null
            AppName   = $appFileName
        }
    }

    # Check if extraction succeeded
    $appJson = Join-Path $extractFolder "app.json"
    if (-not (Test-Path $appJson)) {
        Write-Host "  No app.json found, skipping..."
        return [PSCustomObject]@{
            Success   = $false
            JsonlRoot = $null
            AppName   = $appFileName
        }
    }

    # Check if any .al files contain TransferFields references
    Write-Host "  Scanning for TransferFields references..."
    $alFiles = Get-ChildItem -Path $extractFolder -Recurse -Filter "*.al" -File -ErrorAction SilentlyContinue
    $hasTransferFields = $alFiles | Select-String -Pattern "TransferFields" -List -CaseSensitive:$false | Select-Object -First 1
    
    if (-not $hasTransferFields) {
        Write-Host "  No TransferFields references found, skipping compilation"
        return [PSCustomObject]@{
            Success   = $true
            JsonlRoot = $null
            AppName   = $appFileName
        }
    }

    Write-Host "  TransferFields reference found, proceeding with compilation"

    # Run AL compiler with the Analyzer as a code cop
    Write-Host "  Running AL compiler with TransferFields Analyzer..."

    $compileArgs = @(
        "/project:$extractFolder",
        "/analyzer:$AnalyzerDll",
        "/packagecachepath:$PlatformPath",
        "/parallel+",
        "/generatecode-",
        "/generatereportlayout-",
        "/continuebuildonerror+"
    )

    # Resolve AL tool path
    $alTool = if ($env:HOME) {
        Join-Path $env:HOME ".dotnet/tools/AL"
    }
    else {
        Join-Path $env:USERPROFILE ".dotnet/tools/al.exe"
    }

    # Show full command for debugging
    $quotedArgs = $compileArgs | ForEach-Object { '"{0}"' -f $_ }
    Write-Host "  Full command: $alTool compile $($quotedArgs -join ' ')"

    # Run the AL compiler
    & $alTool compile @compileArgs
    $alExitCode = $LASTEXITCODE
    Write-Host "  AL compile exit code: $alExitCode"
    
    # Reset LASTEXITCODE - we don't care about compilation success, only the JSON output
    $global:LASTEXITCODE = 0

    # Check for generated JSONL files
    $tempPath = [System.IO.Path]::GetTempPath()
    $jsonlRoot = Join-Path $tempPath "ALCops/TransferFields"

    if (Test-Path $jsonlRoot) {
        $jsonlFiles = Get-ChildItem $jsonlRoot -Recurse -Filter relations.jsonl -ErrorAction SilentlyContinue
        if ($jsonlFiles) {
            Write-Host "  Found $($jsonlFiles.Count) relations.jsonl file(s)"
            return [PSCustomObject]@{
                Success   = $true
                JsonlRoot = $jsonlRoot
                AppName   = $appFileName
            }
        }
    }

    Write-Warning "Text pre-scan matched 'TransferFields' but analyzer produced no output (likely comments, partial matches, or filtered calls)"
    return [PSCustomObject]@{
        Success   = $true
        JsonlRoot = $null
        AppName   = $appFileName
    }
}
finally {
    # Cleanup extracted folder
    if (Test-Path $extractFolder) {
        Remove-Item $extractFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
