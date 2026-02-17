# TransferFieldsCollector

A helper tool for the ALCops [analyzers](https://github.com/ALCops/Analyzers) that extracts all `TransferFields` method invocations from the Business Central AL compiler and generates a static C# lookup table of coupled table pairs. ALCops analyzers uses this lookup table to detect field mismatches in table extensions at design time, preventing runtime errors.

## Problem

In Business Central, `TransferFields` copies field values between two table records by matching field numbers. When a developer creates a table extension that adds fields to one of those coupled tables but not the other, the mismatch causes silent data loss or runtime errors. The AL compiler does not warn about this.

To build a diagnostic rule that catches these mismatches, you first need a complete map of which tables are coupled via `TransferFields` across all BC versions and country localizations. That is what this project produces.

## How It Works

The project has three phases: collection, aggregation, and code generation. The first two run entirely via GitHub Actions workflows; only the final code generation step is manual.

### The Analyzer (C# Compiler Plugin)

[TransferFieldsRelationsJsonCollector.cs](src/TransferFieldsRelationsJsonCollector.cs) is a Roslyn-style diagnostic analyzer that plugs into the AL compiler (`Microsoft.Dynamics.Nav.CodeAnalysis`). When the compiler processes a BC app, the analyzer:

1. Intercepts every `TransferFields` invocation.
2. Resolves the source and target table symbols.
3. Filters out non-extensible tables (system, virtual, temporary) and self-relations.
4. Writes each relation as a JSONL record to a temp directory, including the originating extension's AppId, name, publisher, and version.

The analyzer does not produce user-facing diagnostics. It exists solely to harvest data.

### GitHub Workflows

The collection pipeline is fully automated via two GitHub Actions workflows.

#### 1. Delegator ([delegator.yml](.github/workflows/delegator.yml))

Runs on a schedule (7th and 14th of each month) or manually via `workflow_dispatch`. It:

1. Installs `BcContainerHelper` and discovers available BC artifact versions starting from a configurable major/minor.
2. Iterates through every major.minor combination (e.g., 27.0, 27.1, ..., 27.9, 28.0, ...) until no further major versions are found.
3. For each valid version, dispatches the **Analyze BC Version** workflow with a short delay between dispatches.

#### 2. Analyze BC Version ([analyze-version.yml](.github/workflows/analyze-version.yml))

Receives a single BC version (e.g., `27.2`) and processes it end-to-end:

| Job | What it does |
|---|---|
| **build-analyzer** | Builds the TransferFieldsCollector analyzer DLL against the latest `Microsoft.Dynamics.BusinessCentral.Development.Tools`. |
| **create-matrix** | Checks which country localizations (46 countries, from `at` to `w1`) have artifacts available for the given version. Produces a matrix of `{country, version, url}` entries. |
| **analyze-apps** (matrix) | Runs in parallel per country. Downloads BC artifacts via `BcContainerHelper`, invokes the analyzer on every `.app` file using the composite action [analyze-bc-apps](.github/actions/analyze-bc-apps/action.yml), converts JSONL output to JSON, merges per-app results, and uploads the per-country result as an artifact. |
| **aggregate-results** | Downloads all per-country artifacts, merges them into a single `TransferFieldsRelations-<version>.json` file using [Merge-CountryResults.ps1](.github/scripts/Merge-CountryResults.ps1), and commits it directly to the [TransferFields/](TransferFields/) folder in the repository. |

The end result is one JSON file per BC version, committed to the repo automatically. The repository currently contains data for BC versions **16.0 through 27.4** (72+ files covering approximately 6 years of releases and country localizations).

### Code Generation (PowerShell)

A PowerShell script in [TransferFieldsRelations/](TransferFieldsRelations/) reads all per-version JSON files, merges relations across versions, and generates a C# source file containing a static array of relation records with version bounds (`MinVersion`, `MaxVersion`). Relations that still exist in the latest collected version get a `null` upper bound, meaning they are assumed to persist going forward.

The generated file (`TransferFieldsRelations.cs`) must be manually copied into the [ALCops](https://github.com/ALCops/Analyzers) analyzer project to be consumed by analyzer rules.

## JSON Schema

Each versioned JSON file in [TransferFields/](TransferFields/) follows this structure:

```json
{
  "version": "24.3",
  "totalRelations": 391,
  "relations": [
    {
      "source": "Sales Header",
      "sourceNamespace": "Microsoft.Sales.Document",
      "sourceObjectId": 36,
      "target": "Sales Invoice Header",
      "targetNamespace": "Microsoft.Sales.History",
      "targetObjectId": 112,
      "foundInExtensions": {
        "appId": "437dbf0e-84ff-417a-965d-ed2bb9650972",
        "name": "Base Application",
        "publisher": "Microsoft",
        "countries": ["at", "au", "be", "..."],
        "foundInObjects": [
          {
            "foundInObjectQualified": "Microsoft.Sales.Posting.Sales-Post",
            "foundInMethod": "InsertInvoiceHeader"
          }
        ]
      }
    }
  ]
}
```

## Code Generation

Run the PowerShell script to regenerate the C# lookup table from the collected JSON files:

```powershell
# From the repository root
.\TransferFieldsRelations\Generate-TransferFieldsRelations.ps1 `
    -JsonFolder .\TransferFields `
    -OutputPath .\TransferFieldsRelations\TransferFieldsRelations.cs
```

| Parameter     | Default                      | Description                              |
|---------------|------------------------------|------------------------------------------|
| `-JsonFolder` | *(required)*                 | Path to the folder containing the versioned JSON files |
| `-OutputPath` | *(required)*                 | Path for the generated C# file           |
| `-ClassName`  | `TransferFieldsRelations`    | Name of the generated C# class           |

## License

[MIT](LICENSE)
