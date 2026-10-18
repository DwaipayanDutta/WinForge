# WinForge architecture

Front ends (CLI `WinForge.ps1`, GUI `UI/MainForm.ps1`, portable) call one engine.
Only the engine touches Windows, and only through `Adapters/*`.

Pipeline: load catalog -> compatibility gate -> capture state -> plan (preview) ->
authorize (Expert gate for Danger) -> apply via adapters -> verify via
`Verification.Type` -> write run record.

Invariants:
- No catalog field can execute free-form PowerShell.
- Profiles may never contain a Danger tweak (enforced in `Test-WinForgeCatalog`).
- Undo is only offered when `Undo.Strategy = RestoreCapturedState` and state was captured.