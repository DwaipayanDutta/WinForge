# Changelog

## Unreleased

Security
- Run records and logs moved to `%ProgramData%\WinForge`, writable only by SYSTEM and
  Administrators. Undo refuses records whose targets differ from the catalog.
- Catalog validation is enforced at runtime and rejects unknown fields, wildcards,
  path traversal and registry locations that launch code.
- Package IDs are validated; winget is pinned to `--source winget`.
- Update downloads must come from WinForge's GitHub releases and match SHA256SUMS exactly.
- Removed `danger-disable-defender-realtime`: Tamper Protection ignores the policy, so
  the tweak reported success while protection stayed on.

Fixes
- Edition-scoped tweaks were skipped on every Home/Pro PC (`Professional` vs `Pro`).
- Apply now requires confirmation; the preview shows current and new values.
- Run records are written before each change; partial failures roll back automatically.
- Undo restores newest-first, records itself, and does not run twice.
- Services: `Auto` vs `Automatic` broke verification and undo; delayed start is restored.
- Registry: REG_EXPAND_SZ restored unexpanded; Binary/MultiString types preserved; keys
  WinForge created are removed on undo.
- Optional features: pending-restart states verify correctly; reading them without
  elevation reports "unknown" instead of crashing.
- Preview of task/service/feature/Appx tweaks crashed; `List` crashed without elevation.
- `autounattend.xml` was not valid XML (`wcm` prefix undeclared); inputs are validated
  and escaped; disk wipe is no longer generated; the blank password must be changed.
- GUI apply never showed results (timer lost its runner); wizard applied without preview.
- `Print to PDF` tweak targeted the XPS feature.
- `WinForge.bat` dropped its arguments when elevating; `-Tweak a,b` now works via `-File`.
- Tests no longer write to the real registry; Pester 5 scoping bugs fixed; CI runs the
  analyzer (failing on findings), catalog validation and Pester on Windows PowerShell 5.1.

## 0.1.0
- Initial scaffold: engine, adapters, catalog schema, profiles, Expert gate,
  run records, undo, Pester tests, CI, packaging.
