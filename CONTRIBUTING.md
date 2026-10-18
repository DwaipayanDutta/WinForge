# Contributing

Tweak PR checklist:
- Microsoft documentation link or reproducible test evidence in `SourceUrl`
- `Risk` level (Safe / Caution / Danger) and `Reversible` label
- `Undo.Strategy` and, where relevant, the exact registry kind
- builds and editions actually tested
- `.\WinForge.ps1 -Command ValidateCatalog` passes
- Pester suite passes