<#
.SYNOPSIS
    Reads TransferFieldsRelations-*.json files and generates a C# file with an ImmutableArray<TableRelation> initializer.

.DESCRIPTION
    This script processes multiple JSON files containing TransferFields relations, merges them,
    and generates a C# class with version range information extracted from FoundInExtensions.

.PARAMETER JsonFolder
    Path to the folder containing TransferFieldsRelations-*.json files.

.PARAMETER OutputPath
    Path to the output .cs file.

.PARAMETER Namespace
    The C# namespace for the generated class. Default: ALCops.PlatformCop.Helpers

.PARAMETER ClassName
    The C# class name. Default: TransferFieldsRelations

.EXAMPLE
    .\Generate-TransferFieldsRelations.ps1 -JsonFolder "..\TransferFields" -OutputPath ".\TransferFieldsRelations.cs"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $JsonFolder,

    [Parameter(Mandatory = $true)]
    [string] $OutputPath,

    [string] $Namespace = "ALCops.PlatformCop.Helpers",
    [string] $ClassName = "TransferFieldsRelations"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Escape-CSharpString([string] $s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    return $s.Replace('\', '\\').Replace('"', '\"')
}

function Parse-Version([string] $versionString) {
    if ([string]::IsNullOrWhiteSpace($versionString)) { return $null }
    try {
        return [Version]::Parse($versionString)
    }
    catch {
        Write-Warning "Failed to parse version: $versionString"
        return $null
    }
}

function Format-VersionCSharp([Version] $version) {
    if ($null -eq $version) { return "null" }
    return "new Version($($version.Major), $($version.Minor))"
}

# Validate input folder
if (-not (Test-Path -LiteralPath $JsonFolder -PathType Container)) {
    throw "JSON folder not found: $JsonFolder"
}

# Find all JSON files matching the pattern
$jsonFiles = Get-ChildItem -Path $JsonFolder -Filter "TransferFieldsRelations-*.json" -File
if ($jsonFiles.Count -eq 0) {
    throw "No TransferFieldsRelations-*.json files found in: $JsonFolder"
}

Write-Host "Found $($jsonFiles.Count) JSON file(s) to process:"
$jsonFiles | ForEach-Object { Write-Host "  - $($_.Name)" }

# Dictionary to track unique relations with their version ranges
$relationsMap = @{}

# Track the overall maximum version across all files
$overallMaxVersion = $null

foreach ($jsonFile in $jsonFiles) {
    Write-Host "`nProcessing: $($jsonFile.Name)"

    $jsonText = Get-Content -LiteralPath $jsonFile.FullName -Raw -Encoding UTF8
    $data = $jsonText | ConvertFrom-Json

    if ($null -eq $data -or $null -eq $data.relations) {
        Write-Warning "  Skipping - no relations found"
        continue
    }

    $relationCount = 0
    foreach ($relation in $data.relations) {
        if ([string]::IsNullOrWhiteSpace($relation.Source) -or [string]::IsNullOrWhiteSpace($relation.Target)) {
            continue
        }

        $sourceNs = if ($null -ne $relation.SourceNamespace) { $relation.SourceNamespace } else { "" }
        $source = $relation.Source
        $targetNs = if ($null -ne $relation.TargetNamespace) { $relation.TargetNamespace } else { "" }
        $target = $relation.Target

        # Key is based on object names only (without namespace) to merge entries with/without namespace
        $key = "$source|$target"

        $versions = @()
        if ($null -ne $relation.FoundInExtensions) {
            foreach ($ext in $relation.FoundInExtensions) {
                if ($null -ne $ext.Version) {
                    $ver = Parse-Version $ext.Version
                    if ($null -ne $ver) {
                        $versions += $ver
                    }
                }
            }
        }

        if ($relationsMap.ContainsKey($key)) {
            $existing = $relationsMap[$key]

            # Prefer non-empty namespace when merging
            if ([string]::IsNullOrEmpty($existing.SourceNamespace) -and -not [string]::IsNullOrEmpty($sourceNs)) {
                $existing.SourceNamespace = $sourceNs
            }
            if ([string]::IsNullOrEmpty($existing.TargetNamespace) -and -not [string]::IsNullOrEmpty($targetNs)) {
                $existing.TargetNamespace = $targetNs
            }

            foreach ($ver in $versions) {
                if ($null -eq $existing.MinVersion -or $ver -lt $existing.MinVersion) {
                    $existing.MinVersion = $ver
                }
                if ($null -eq $existing.MaxVersion -or $ver -gt $existing.MaxVersion) {
                    $existing.MaxVersion = $ver
                }
                # Update overall max version
                if ($null -eq $overallMaxVersion -or $ver -gt $overallMaxVersion) {
                    $overallMaxVersion = $ver
                }
            }
        }
        else {
            $minVer = $null
            $maxVer = $null

            if ($versions.Count -gt 0) {
                $minVer = ($versions | Sort-Object)[0]
                $maxVer = ($versions | Sort-Object)[-1]
            }

            # Update overall max version
            foreach ($ver in $versions) {
                if ($null -eq $overallMaxVersion -or $ver -gt $overallMaxVersion) {
                    $overallMaxVersion = $ver
                }
            }

            # Use a Hashtable so properties can be modified later
            $relationsMap[$key] = @{
                SourceNamespace = $sourceNs
                Source          = $source
                TargetNamespace = $targetNs
                Target          = $target
                MinVersion      = $minVer
                MaxVersion      = $maxVer
            }
            $relationCount++
        }
    }

    Write-Host "  Added $relationCount new relations"
}

$sortedRelations = $relationsMap.Values | Sort-Object SourceNamespace, Source, TargetNamespace, Target

Write-Host "`nTotal unique relations: $($sortedRelations.Count)"
Write-Host "Overall max version found: $overallMaxVersion (relations at this version will have no upper bound)"

$lines = [System.Collections.Generic.List[string]]::new()

$lines.Add("// <auto-generated />")
$lines.Add("// This file is generated by Generate-TransferFieldsRelations.ps1")
$lines.Add("// Do not modify manually.")
$lines.Add("//")
$lines.Add("// Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("// Total relations: $($sortedRelations.Count)")
$lines.Add("")
$lines.Add("using System;")
$lines.Add("using System.Collections.Immutable;")
$lines.Add("")
$lines.Add("namespace $Namespace;")
$lines.Add("")
$lines.Add("internal static class $ClassName")
$lines.Add("{")
$lines.Add("    /// <summary>")
$lines.Add("    /// Represents a fully qualified object name with namespace and name as separate properties.")
$lines.Add("    /// </summary>")
$lines.Add("    internal readonly record struct ObjectName(string Namespace, string Name)")
$lines.Add("    {")
$lines.Add("        public override string ToString() =>")
$lines.Add('            string.IsNullOrEmpty(Namespace) ? Name : $"{Namespace}.{Name}";')
$lines.Add("    }")
$lines.Add("")
$lines.Add("    /// <summary>")
$lines.Add("    /// Represents a TransferFields relation between a source and target table,")
$lines.Add("    /// with version range indicating in which BC versions this relation was found.")
$lines.Add("    /// </summary>")
$lines.Add('    /// <param name="Source">The source table (record passed to TransferFields)</param>')
$lines.Add('    /// <param name="Target">The target table (instance calling TransferFields)</param>')
$lines.Add('    /// <param name="MinVersion">Minimum BC version where this relation was found (null = no lower bound)</param>')
$lines.Add('    /// <param name="MaxVersion">Maximum BC version where this relation was found (null = no upper bound)</param>')
$lines.Add("    internal readonly record struct TableRelation(")
$lines.Add("        ObjectName Source,")
$lines.Add("        ObjectName Target,")
$lines.Add("        Version? MinVersion,")
$lines.Add("        Version? MaxVersion);")
$lines.Add("")
$lines.Add("    internal static readonly ImmutableArray<TableRelation> TableRelations =")
$lines.Add("        ImmutableArray.Create(")

for ($i = 0; $i -lt $sortedRelations.Count; $i++) {
    $rel = $sortedRelations[$i]

    $srcNs = Escape-CSharpString $rel.SourceNamespace
    $src = Escape-CSharpString $rel.Source
    $tgtNs = Escape-CSharpString $rel.TargetNamespace
    $tgt = Escape-CSharpString $rel.Target

    $minVerStr = Format-VersionCSharp $rel.MinVersion
    
    # If MaxVersion equals the overall max version, treat it as no upper bound (omit it)
    $effectiveMaxVersion = if ($null -ne $rel.MaxVersion -and $null -ne $overallMaxVersion -and $rel.MaxVersion -eq $overallMaxVersion) {
        $null
    }
    else {
        $rel.MaxVersion
    }
    $maxVerStr = Format-VersionCSharp $effectiveMaxVersion

    $comma = if ($i -lt ($sortedRelations.Count - 1)) { "," } else { "" }

    $lines.Add("            new TableRelation(")
    $lines.Add('                new ObjectName("' + $srcNs + '", "' + $src + '"),')
    $lines.Add('                new ObjectName("' + $tgtNs + '", "' + $tgt + '"),')
    $lines.Add("                $minVerStr,")
    $lines.Add("                $maxVerStr)$comma")
}

$lines.Add("        );")
$lines.Add("}")
$lines.Add("")

$outDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$content = $lines -join "`r`n"
Set-Content -LiteralPath $OutputPath -Value $content -Encoding UTF8 -NoNewline

Write-Host "`nGenerated: $OutputPath"
Write-Host "Done!"
