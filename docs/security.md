# Security notes

- **Confirmation.** The engine refuses to apply without `-Force`, which front ends pass
  only after showing the preview: the CLI asks for `YES`, the GUI and wizard show the plan
  in a Yes/No dialog.
- **Danger gate.** Danger tweaks need `-Expert` and `-TypedConfirmation <Id>`. `-Force`
  never bypasses it. Profiles can never contain a Danger tweak.
- **Catalog is data.** No field is executed. Unknown fields are rejected, every target is
  validated per type, wildcards are rejected (an Appx name of `*` would remove every
  package), and registry locations that launch code or disable core protections (Run
  keys, IFEO, Winlogon shell, service ImagePath, COM servers, UAC, LSA packages) are
  refused. The engine validates the catalog on every Preview, Apply, Undo and Install.
- **Package IDs** must match `^[A-Za-z0-9][A-Za-z0-9.+_-]*$` and are passed as discrete
  arguments; winget is pinned to `--source winget --exact`.
- **State folder.** `%ProgramData%\WinForge` is owned by Administrators; SYSTEM and
  Administrators can write, Users can only read. Run records drive elevated Undo, so a
  non-elevated process must not be able to forge one. Undo also refuses any record whose
  targets differ from the catalog's. Portable mode (`.\state`) has no such protection:
  keep the USB stick under your control.
- **Records before changes.** The captured state is written before each tweak is
  applied, so an interrupted run can still be undone.
- **Updates.** Asset URLs must be WinForge's GitHub release downloads, and the zip must
  match `SHA256SUMS.txt`. That proves integrity against the release, not who published
  it; code signing is still to do. Nothing is extracted or run automatically.
- **Answer files.** The generated account starts with a blank password, is forced to set
  one at first sign-in, and Setup's cached copies in `Panther` are deleted. Unattended
  disk partitioning is not generated.
- **Known limitation.** HKCU tweaks apply to the account running WinForge. If you elevate
  with a different administrator account, they change that account, not yours.
