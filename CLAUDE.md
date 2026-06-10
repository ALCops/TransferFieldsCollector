# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TransferFieldsCollector is a data collection pipeline for the ALCops project. It extracts `TransferFields` method invocations from Business Central AL apps across all BC versions and country localizations, then generates a static C# lookup table consumed by ALCops analyzers to detect field mismatches at design time.

## Build

```bash
dotnet build src/ALCops.TransferFieldsCollector.csproj --configuration Release
```

The project targets .NET 8.0 and depends on `Microsoft.Dynamics.BusinessCentral.Development.Tools` for the AL compiler APIs (`Microsoft.Dynamics.Nav.CodeAnalysis`).

## Code Generation

Generate the C# lookup table from collected JSON data:

```powershell
.\TransferFieldsRelations\Generate-TransferFieldsRelations.ps1 `
    -JsonFolder .\TransferFields `
    -OutputPath .\TransferFieldsRelations\TransferFieldsRelations.cs
```

Count unique relation pairs across all versions:

```powershell
.\TransferFieldsRelations\Count-TransferFieldsCouples.ps1
```

## Architecture

### Three-Phase Pipeline

1. **Collection** — `src/TransferFieldsRelationsJsonCollector.cs` is a Roslyn-style `DiagnosticAnalyzer` that plugs into the AL compiler. It intercepts `TransferFields` invocations, resolves source/target table symbols, filters non-extensible tables, and writes JSONL to a temp directory. It reports no user-facing diagnostics.

2. **Aggregation** — Two GitHub Actions workflows automate collection across all BC versions and 46 country localizations:
   - `delegator.yml` discovers available BC versions and dispatches per-version analysis
   - `analyze-version.yml` builds the analyzer, creates a country matrix, runs analysis in parallel per country, then merges results into a single `TransferFields/TransferFieldsRelations-<version>.json`

3. **Code Generation** — `TransferFieldsRelations/Generate-TransferFieldsRelations.ps1` reads all versioned JSON files, merges relations with version bounds (MinVersion/MaxVersion), and outputs a C# file with a static `ImmutableArray<TableRelation>`. The generated file must be manually copied to the ALCops Analyzers repo.

### Key Patterns

- The analyzer uses `ConditionalWeakTable<Compilation, string>` to scope JSONL output per compilation instance.
- Table symbol resolution filters system, virtual, and temporary tables via `TableTypeKind` checks.
- Multi-level aggregation: JSONL → per-app JSON → per-country JSON → per-version JSON. Deduplication uses composite keys (Source|SourceNamespace|Target|TargetNamespace).
- Relations at the latest collected version get `MaxVersion = null` (assumed to persist forward).

### Data Files

`TransferFields/` contains 72+ versioned JSON files (BC 16.0–28.2). These are committed automatically by CI with `[skip ci]` markers. Do not manually edit these files.

### PowerShell Scripts

Scripts in `.github/scripts/` support the CI pipeline:
- `Invoke-SingleAppAnalysis.ps1` — extracts an .app, pre-scans for "TransferFields" text, runs the AL compiler with the analyzer
- `ConvertFrom-RelationsJsonl.ps1` — converts JSONL output to structured JSON
- `Merge-TransferFieldsRelations.ps1` — merges per-app results with deduplication
- `Merge-CountryResults.ps1` — aggregates per-country results, embeds country metadata
- `Get-BCArtifactCountries.ps1` — discovers available localizations for a BC version

### CI/CD

Workflows run on schedule (8th and 14th of each month). The `aggregate-results` job commits directly to the repo using `github-actions[bot]` identity with retry logic for concurrent push conflicts.
