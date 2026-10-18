# Repository audit

Audited 2026-10-18 against the working trees in `D:\Github`.

## Win11DebloatMinimal

- `Run.bat` launches `Win11DebloatMinimal.ps1`, which is not in the repository or its
  history, so the tool cannot start. No loader dot-sources `Core/` or `Modules/`.
- 86 tweak functions; 73 of them are the Aggressive profile, 13 are in no profile.
- `Save-RestoreScript` replays undo actions in forward order: when two tweaks write the
  same value, restore ends on the first tweak's value instead of the original.
- `Disable-ActivityHistory` writes `PublishUserActivity` / `UploadUserActivity`; Windows
  reads the plural names, so the tweak has no effect.
- Restore scripts and logs live in `%TEMP%\Win11Debloat`, which the Aggressive profile's
  `Invoke-CleanTempFiles` deletes after a day.
- Aggressive includes `Disable-BiometricSvc` and `Set-WindowsUpdateNotifyOnly`, which the
  roadmap places behind the Expert gate.
- `Disable-WindowsDefender` reports success although Tamper Protection ignores it.
- `Disable-PrintToPDF` targets `Printing-XPSServices-Features` (XPS), not Print to PDF.

## PrivGuard

- Single script with a working menu loop, SAFE/AGGRESSIVE apply, dry-run preview,
  MONITOR, STATUS, LOGS, SETTINGS and ROLLBACK (`PrivGuard.ps1:814-958`).
- Rollback uses `reg export` / `reg import`. `reg import` never deletes values, and keys
  that did not exist are never exported, so values PrivGuard created survive rollback.
- Each run overwrites the previous backup, so a second run destroys the original state.
- Writes `HasAccepted` under `HKLM\SOFTWARE\Microsoft\Speech_OneCore\Preferences`; verify
  against the documented per-user online-speech setting before migrating.

## What WinForge takes from each

- Per-value state capture (Win11DebloatMinimal's approach), with reverse-order undo and a
  run record per run instead of one overwritten backup.
- PrivGuard's dry-run table, telemetry-level honesty and monitor classification.
