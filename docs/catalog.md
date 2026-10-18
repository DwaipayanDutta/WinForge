# Catalog

`Catalog/tweaks.json` is the single source of truth. Fields and allowed values are in
`Catalog/schema/tweak.schema.json`. Validation runs via:

    .\WinForge.ps1 ValidateCatalog

Rules enforced by `Test-WinForgeCatalog` (and at runtime by `Assert-WinForgeCatalog`):

- required fields present; stable `Id` pattern; no duplicate IDs; no unknown fields
- no `Script` / `Command` / `CommandLine` / `ScriptBlock` / `Expression` fields
- each target validated for its `Type`: hive, path and value name for registry (no `..`,
  wildcards or drive prefixes), value type matching `Kind`; service, task and feature
  names and states from fixed sets; Appx names without wildcards
- registry targets that launch code or weaken core protections are refused
- `Verification.Type`, `Undo.Strategy`, `Risk`, `Reversible`, editions and architectures
  from fixed sets; Appx removal cannot claim `RestoreCapturedState` or `full`
- profiles may not reference unknown IDs or any `Risk = Danger` tweak
- `apps.json` package IDs must be plain identifiers; bundles may only list known apps

`Editions` uses family names (`Home`, `Pro`, `Enterprise`, `Education`); WinForge maps the
machine's `EditionID` (`Core`, `Professional`, `EnterpriseS`, ...) to these. `Notes` is
shown in every preview of the tweak.
