<#
.SYNOPSIS
    Deterministic namespace-casing canonicalization for TransferFields relations.

.DESCRIPTION
    AL namespaces are case-insensitive, but the AL compiler reports whatever literal
    casing a given app declared (e.g. 'Microsoft.EServices.EDocument' in the Base
    Application vs 'Microsoft.eServices.EDocument' in E-Document Core). The collected
    JSON therefore contains the same logical namespace with different casing depending
    on which app/country produced it.

    The merge steps deduplicate case-insensitively (PowerShell @{} hashtables), so the
    surviving casing used to depend on processing order and flipped between CI runs.
    This module replaces that order-dependence with a deterministic canonical casing.

    Canonical casing rule for a set of casings that share the same lower-case form:
      1. If any observation came from the 'w1' localization, use the W1 casings.
      2. Otherwise use all observed casings.
      3. Within the chosen set, pick the ordinally-smallest casing
         ([System.StringComparer]::Ordinal). This is stable and order-independent.

    The W1 preference only matters at the cross-country merge (Merge-CountryResults),
    where the originating country is known. The per-app merge (Merge-TransferFieldsRelations)
    runs within a single country, so it passes IsW1 = $false everywhere and falls back to
    the ordinal-min rule, which is what makes each per-country file stable in the first place.
#>

# Creates a new, empty casing registry.
function New-NamespaceCasingRegistry {
    return @{}  # lowerNamespace -> @{ All = @{casing=$true}; W1 = @{casing=$true} }
}

# Records one observation of a namespace's literal casing.
# NOTE: the casing sets MUST be case-sensitive (ordinal) — the whole point is to keep
# casings that differ only by case (e.g. 'eServices' vs 'EServices') distinct. A plain
# PowerShell @{} hashtable is case-insensitive and would collapse them.
function Add-NamespaceObservation {
    param(
        [Parameter(Mandatory)] [hashtable] $Registry,
        [string] $Namespace,
        [bool] $IsW1 = $false
    )

    if ([string]::IsNullOrWhiteSpace($Namespace)) { return }

    $key = $Namespace.ToLowerInvariant()
    if (-not $Registry.ContainsKey($key)) {
        $Registry[$key] = @{
            All = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            W1  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        }
    }

    [void]$Registry[$key].All.Add($Namespace)
    if ($IsW1) { [void]$Registry[$key].W1.Add($Namespace) }
}

# Returns the canonical casing for a namespace, or the input unchanged when unknown.
function Resolve-CanonicalNamespace {
    param(
        [Parameter(Mandatory)] [hashtable] $Registry,
        [string] $Namespace
    )

    if ([string]::IsNullOrWhiteSpace($Namespace)) { return $Namespace }

    $key = $Namespace.ToLowerInvariant()
    if (-not $Registry.ContainsKey($key)) { return $Namespace }

    $entry = $Registry[$key]
    $set = if ($entry.W1.Count -gt 0) { $entry.W1 } else { $entry.All }

    $sorted = @($set)
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return [string]$sorted[0]
}

# Rewrites the namespace prefix of a fully-qualified object name ("<namespace>.<object>")
# to its canonical casing. Object names may contain dots, so the namespace portion is
# identified by matching the longest known namespace (case-insensitive) followed by a dot.
function Resolve-CanonicalQualifiedName {
    param(
        [Parameter(Mandatory)] [hashtable] $Registry,
        [string] $Qualified,
        # Known lower-case namespace keys, pre-sorted by length descending (longest first).
        [string[]] $NamespaceKeysByLengthDesc
    )

    if ([string]::IsNullOrWhiteSpace($Qualified)) { return $Qualified }

    $lower = $Qualified.ToLowerInvariant()
    foreach ($nsLower in $NamespaceKeysByLengthDesc) {
        $prefixLen = $nsLower.Length
        if ($Qualified.Length -gt ($prefixLen + 1) -and
            $lower.Substring(0, $prefixLen) -eq $nsLower -and
            $Qualified[$prefixLen] -eq '.') {
            $originalNs = $Qualified.Substring(0, $prefixLen)
            $canonicalNs = Resolve-CanonicalNamespace -Registry $Registry -Namespace $originalNs
            return $canonicalNs + $Qualified.Substring($prefixLen)
        }
    }

    return $Qualified
}

# Returns known namespace keys sorted by length descending (for longest-prefix matching).
function Get-NamespaceKeysByLengthDesc {
    param([Parameter(Mandatory)] [hashtable] $Registry)
    return @($Registry.Keys | Sort-Object -Property Length -Descending)
}

# Records one observation of a fully-qualified object name ("<namespace>.<object>") in a
# separate "qualified" registry, after normalizing its namespace prefix to the canonical
# casing. The namespace portion of a found-in object cannot be parsed out reliably on its
# own (object names may contain dots), and such a namespace is frequently NOT a table
# Source/Target namespace, so it is absent from the namespace registry. Resolving the whole
# qualified string against this registry (lower-case keyed, w1/ordinal-min selection) makes
# its casing deterministic regardless of processing order.
function Add-QualifiedObservation {
    param(
        [Parameter(Mandatory)] [hashtable] $NamespaceRegistry,
        [Parameter(Mandatory)] [hashtable] $QualifiedRegistry,
        [string] $Qualified,
        [string[]] $NamespaceKeysByLengthDesc,
        [bool] $IsW1 = $false
    )

    if ([string]::IsNullOrWhiteSpace($Qualified)) { return }

    $prefixed = Resolve-CanonicalQualifiedName -Registry $NamespaceRegistry -Qualified $Qualified -NamespaceKeysByLengthDesc $NamespaceKeysByLengthDesc
    Add-NamespaceObservation -Registry $QualifiedRegistry -Namespace $prefixed -IsW1:$IsW1
}

# Returns the canonical, order-independent casing of a fully-qualified object name.
# The namespace prefix is first rewritten to its canonical casing (keeping it consistent
# with table namespaces where the namespace is known), then the entire string is resolved
# against the qualified registry so any remaining casing differences — including namespaces
# that only ever appear inside found-in objects, and object-name casing — collapse to a
# single deterministic survivor.
function Resolve-CanonicalQualifiedNameStable {
    param(
        [Parameter(Mandatory)] [hashtable] $NamespaceRegistry,
        [Parameter(Mandatory)] [hashtable] $QualifiedRegistry,
        [string] $Qualified,
        [string[]] $NamespaceKeysByLengthDesc
    )

    if ([string]::IsNullOrWhiteSpace($Qualified)) { return $Qualified }

    $prefixed = Resolve-CanonicalQualifiedName -Registry $NamespaceRegistry -Qualified $Qualified -NamespaceKeysByLengthDesc $NamespaceKeysByLengthDesc
    return Resolve-CanonicalNamespace -Registry $QualifiedRegistry -Namespace $prefixed
}
