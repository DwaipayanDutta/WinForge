# WinForge

**Forge the Windows you want.**

Preview-first Windows debloat, privacy, and app-install toolkit. A shared engine, a data-driven catalog, and per-operation rollback. One tool for fresh installs and existing PCs.

> WinForge is an independent project. It is not affiliated with, endorsed by, or supported by Microsoft.

---

## Status

**Early public build.** The engine, catalog validator, adapters, rollback, installer, deploy, updates, monitor, and WinForms UI are implemented. Some rough edges remain — see [Known limitations](#known-limitations). Do not run `Apply` against a machine you are not prepared to rebuild. Test in a VM first.

The current version is not code-signed. Antivirus and SmartScreen may flag the launcher; there is no obfuscation or packing, and every source file is readable.

---

## What it does

WinForge changes Windows settings in five areas, every change wrapped in the same safety pipeline:

| Area | What it does | Reversible? |
|---|---|---|
| **Debloat** | Remove selected Appx packages; disable consumer features, feedback and telemetry tasks, and diagnostic services | Appx: partial (current user only; new users get the app back). Tasks/services: full |
| **Privacy** | Diagnostic data, advertising ID, tailored experiences, activity history, Copilot, Recall, Edge and Office policies | Full |
| **Security** | Read-only posture audit of Defender, Firewall, SmartScreen, device encryption | N/A (read-only) |
| **Installer** | Install apps and bundles via winget (default) or Chocolatey (opt-in) | Reinstall/uninstall via the same provider |
| **Deploy** | Generate `autounattend.xml`; portable mode; offline cache | N/A (generated files) |
| **Updates** | Check GitHub Releases, verify SHA256, download | N/A |

Riskier settings sit behind an **Expert gate** and never appear in a shipped profile.

---

## Requirements

- **Windows 10 1809+ or Windows 11** (x64 or ARM64). Windows 11 recommended.
- **Windows PowerShell 5.1** (the one that ships with Windows). PowerShell 7 is not supported for the GUI runspace; the CLI may work but is untested.
- **Administrator privileges** to apply changes, install apps, or read most security posture data. `Preview`, `List`, `Status`, `History`, `ValidateCatalog`, and the read-only audit run without elevation.
- **winget** (ships with Windows 11 and recent Windows 10). **Chocolatey is not bundled and is never installed silently** — install it yourself if you want the fallback.
- **Pester 5.5+** and **PSScriptAnalyzer** only if you want to run the tests.

---

## Quick start

```powershell
git clone https://github.com/DwaipayanDutta/WinForge.git
cd WinForge

# 1. Validate the shipped catalog. Should print "Catalog OK".
.\WinForge.ps1 -Command ValidateCatalog

# 2. See what the tool would do — no changes are made.
.\WinForge.ps1 -Command List
.\WinForge.ps1 -Command Preview -Profile Minimal

# 3. Apply a profile from an elevated prompt.
.\WinForge.ps1 -Command Apply -Profile Minimal

# 4. Inspect the run and undo it if needed.
.\WinForge.ps1 -Command History
.\WinForge.ps1 -Command Undo -RunId <id-from-history>

# 5. Open the GUI (elevates automatically via WinForge.bat).
.\WinForge.bat
```

**Test in a VM first.** Apply and undo write real state; some tweaks need a reboot, and Appx removal is not fully reversible.

---

## CLI reference

`WinForge.ps1` takes a single `-Command` and optional parameters.

```text
.\WinForge.ps1 -Command <name> [options]
```

| Command | What it does | Needs admin? |
|---|---|---|
| `Help` | Full parameter help | No |
| `ValidateCatalog` | Validate the catalog and profiles; exit non-zero on error | No |
| `List` | List all tweaks with category, risk, current state, compatibility | No |
| `Status -Tweak <id>` / `-Profile <name>` | Current state of one or more tweaks | No |
| `Preview -Profile <name>` / `-Tweak <id>` | Dry run: current → planned state for every target | No |
| `Apply -Profile <name>` / `-Tweak <id>` | Apply and verify | **Yes** |
| `Undo -RunId <id> [-Tweak <id>]` | Restore captured state for one tweak or a whole run | **Yes** |
| `History` | List runs with applied/failed counts | No |
| `Dashboard` | System info, providers, last run, security posture | No |
| `Privacy` | Privacy posture summary with edition honesty note | No |
| `Monitor` | Current TCP connections with process attribution | No |
| `Audit` | Read-only Defender / Firewall / SmartScreen / BitLocker status | No* |
| `Install -Bundle <name>` | Install a bundle (dry run by default; `-Force` to install) | **Yes** |
| `Deploy -OutFile <path>` | Generate `autounattend.xml` | No |
| `UpdateCheck [-Force]` | Check for a newer release; `-Force` downloads and verifies SHA256 | No / **Yes** for download |
| `Gui` | Launch the WinForms UI | No to open; **yes** to apply |
| `Wizard` | Three-question quick-setup for beginners | **Yes** |

\* Some audit readings (BitLocker) return “Unavailable” without elevation. That is intentional: WinForge does not guess.

### Parameters

| Parameter | Used by | Purpose |
|---|---|---|
| `-Tweak <id>[,<id>...]` | `Status`, `Preview`, `Apply`, `Undo` | One or more catalog IDs |
| `-Profile <name>` | `Status`, `Preview`, `Apply` | `Minimal`, `Recommended`, or `Aggressive` |
| `-RunId <id>` | `Undo` | The run to undo |
| `-Bundle <name>` | `Install` | `Essentials`, `Dev`, `Gaming`, or `Security` |
| `-OutFile <path>` | `Deploy` | Where to write `autounattend.xml` |
| `-Expert` | `Apply` | Required for `Danger` tweaks |
| `-TypedConfirmation <id>` | `Apply` | Must exactly match the `Danger` tweak ID |
| `-Force` | `Apply`, `Install`, `UpdateCheck` | Skip the routine confirmation; **does not bypass the Expert gate** |
| `-StateRoot <path>` | Any | Override the state directory (default `%ProgramData%\WinForge`) |

### Examples

```powershell
# Preview a single tweak
.\WinForge.ps1 -Command Preview -Tweak privacy-disable-advertising-id

# Apply three specific tweaks
.\WinForge.ps1 -Command Apply -Tweak privacy-disable-advertising-id,privacy-disable-tailored-experiences,taskbar-align-left

# Undo only one tweak from a multi-tweak run
.\WinForge.ps1 -Command Undo -RunId 20261018T140211Z-7F3A -Tweak taskbar-align-left

# Dry-run a bundle install
.\WinForge.ps1 -Command Install -Bundle Essentials

# Actually install the bundle
.\WinForge.ps1 -Command Install -Bundle Essentials -Force

# Check for updates; download and verify the zip
.\WinForge.ps1 -Command UpdateCheck -Force
```

---

## Profiles

Profiles are lists of catalog IDs. They can never contain a `Danger` tweak — the validator rejects that.

| Profile | What it includes | Reboot? |
|---|---|---|
| **Minimal** | Privacy-safe tweaks only: advertising ID, tailored experiences, Start suggestions, Spotlight, Bing search, Cortana policy, etc. No services, no app removal. | No |
| **Recommended** | Minimal plus telemetry policy (Pro/Enterprise only), consumer features, Copilot, Explorer and taskbar tweaks. | Usually no |
| **Aggressive** | Recommended plus telemetry tasks and services, safe Appx removals, Remote Registry disabled. | Yes |

Edit `Catalog/profiles.json` to change what a profile does, or add a new profile. The validator will reject any profile that references an unknown ID or a `Danger` tweak.

---

## Catalog

`Catalog/tweaks.json` is the single source of truth. Every tweak is data — no code paths, no free-form scripts.

Fields:

| Field | Required | Purpose |
|---|---|---|
| `Id` | Yes | Stable slug, pattern `^[a-z0-9][a-z0-9-]{2,63}$` |
| `Name`, `Description` | Yes | Shown in the UI and CLI |
| `Category` | Yes | `Debloat`, `Privacy`, `Security`, `System`, `Taskbar`, `Start`, `Explorer` |
| `Risk` | Yes | `Safe`, `Caution`, `Danger` |
| `Reversible` | Yes | `full`, `partial`, `none` |
| `Targets` | Yes | One or more of `Registry`, `Service`, `ScheduledTask`, `OptionalFeature`, `Appx` |
| `Verification` | Yes | Type name; recorded for future use |
| `Undo` | Yes | `RestoreCapturedState`, `ReinstallAppx`, `Manual`, `None` |
| `NeedsRestart` | Yes | Whether a reboot is expected for the change to take effect |
| `MinBuild`, `MaxBuild` | No | Windows build range |
| `Editions` | No | `Home`, `Pro`, `Enterprise`, `Education` |
| `Architecture` | No | `x64`, `ARM64` |
| `SourceUrl` | No (recommended for Caution/Danger) | Microsoft documentation or test evidence |

`Catalog/schema/tweak.schema.json` is the authoritative schema. `Catalog/apps.json` and `Catalog/bundles.json` drive the installer.

### Safety validation

`ValidateCatalog` enforces more than the schema:

- **No execution fields.** `Script`, `Command`, `CommandLine` are rejected outright.
- **Registry deny-list.** Writes to `Run`, `RunOnce`, `Image File Execution Options`, `Winlogon`, `AppInit_DLLs`, `Lsa`, `UAC`, service `ImagePath`, and shell `command` keys are rejected. A catalog entry cannot be used to achieve code execution.
- **Profile safety.** A profile that references an unknown ID or a `Danger` tweak fails validation.
- **Duplicate IDs.** Rejected.

Run it after any catalog change:

```powershell
.\WinForge.ps1 -Command ValidateCatalog
```

---

## Safety model

Every system-changing operation goes through the same pipeline in `Core/Engine.ps1`:

1. **Validate the catalog.** No change proceeds if the catalog has errors.
2. **Compatibility gate.** Build, edition, architecture, and managed-device checks. Unsupported tweaks are `Skipped` with a reason — never reported as success.
3. **Capture prior state.** Registry value + existence + exact kind; service start mode + delayed flag + status; scheduled-task state; optional-feature state; Appx presence. Snapshots are saved *before* the apply, so a crash still leaves an undoable record.
4. **Plan.** Current state → desired state, per target. This is what `Preview` shows.
5. **Authorize.** `Danger` tweaks require both `-Expert` and `-TypedConfirmation <Id>`. `-Force` does not bypass this.
6. **Apply.** Through adapters only. On a mid-tweak failure, WinForge rolls back the targets that did change (newest first) and records `RolledBack` or `Partial`.
7. **Verify.** Re-reads state after apply. A zero exit code is not treated as success.
8. **Record.** Structured run record in `StateRoot\runs\<RunId>.json`, with before/after snapshots, status, and rollback metadata.

### Rollback

Undo restores the captured state:

- **Registry:** restores exact kind and value if the value existed; removes the value if it did not; removes the key if WinForge created it and it is now empty. `REG_EXPAND_SZ` values are preserved unexpanded.
- **Service:** restores `Automatic`, `Automatic (Delayed Start)`, `Boot`, `System`, `Manual`, `Disabled`.
- **Scheduled task:** restores enabled/disabled state.
- **Optional feature:** restores enabled/disabled state.
- **Appx:** refuses `RestoreCapturedState` and reports `NotReversible`. Reinstall from the Store (or let WinForge reinstall via winget where possible).

Undo is available per tweak (`-Tweak`) or for a whole run. The run record is ACL-protected; only Administrators and SYSTEM can modify it.

### Expert gate

`Danger` tweaks — disabling Defender real-time protection, disabling Windows Firewall, disabling the Print Spooler service — are never in a profile and cannot be applied without:

```powershell
.\WinForge.ps1 -Command Apply -Tweak danger-disable-firewall `
    -Expert -TypedConfirmation danger-disable-firewall
```

The ID must be typed exactly. A wrong confirmation throws.

---

## Modules

### Debloat

See `List` or the GUI Tweaks tab. Most tweaks are Safe or Caution. Appx removals are `Caution` and `Reversible: partial` — WinForge removes for the current user only; other users and provisioned packages are unaffected.

### Privacy

`Privacy` prints the current privacy posture, plus a per-edition honesty note:

- **Home / Core:** `AllowTelemetry=0` is treated as `Required (1)` by Windows. The UI says so rather than implying telemetry is off.
- **Pro:** same unless the device is Enterprise-managed.
- **Enterprise / Education:** `0` is honoured.

### Monitor

`Monitor` lists current TCP connections with process attribution. The `Class` column is marked `Unclassified` — it does not perform reverse DNS or heuristic labeling. `Export-WinForgeConnectionSnapshot` and `Compare-WinForgeConnectionSnapshots` exist in `Modules/Monitor.ps1` for before/after comparison, but are not yet wired to the CLI or GUI.

### Security audit

`Audit` reports Defender real-time state, Firewall profile state, SmartScreen policy, and BitLocker protection. Values that cannot be read are shown as `Unavailable` — WinForge does not guess. BitLocker requires elevation.

### Installer

- **winget is default.** The tool verifies installation by running `winget list` after the install and checking the exact ID appears.
- **Chocolatey is opt-in.** Never installed silently. Some packages lag behind winget; the tool prefers winget when both are available.
- **Bundles** are data: `Essentials`, `Dev`, `Gaming`, `Security (opt-in)`. The Security bundle is empty by default and unchecked; installing third-party real-time AV usually switches Defender off, so this is a deliberate choice.
- **Install history** is not yet persisted to disk. The report is shown at the end of the run but not saved.

### Deploy

`Deploy -OutFile path.xml` generates a validated `autounattend.xml` for use with Rufus, Ventoy, or a manual USB. By default the generated file does **not** include a disk-wipe step. The generated file leaves passwords blank — this is deliberate, because answer-file passwords are readable in the file and a copy remains in `C:\Windows\Panther`. Set the password at first login.

The first-boot hook (`FirstLogonCommands`) is present but runs in the user token, which can fail on some Windows editions. A `$OEM$\$$\Setup\Scripts\SetupComplete.cmd` hook (SYSTEM context) is the recommended alternative; it is documented in `docs/architecture.md`.

**Out of scope:** TPM bypass, Secure Boot bypass, activation, bundling ISOs. Use Rufus for those.

### Updates

`UpdateCheck` queries `https://api.github.com/repos/DwaipayanDutta/WinForge/releases/latest`, checks that the asset URL belongs to the WinForge release, downloads the zip, and verifies its SHA256 against the published `SHA256SUMS.txt`. Downloads never happen unless `-Force` is passed, and a hash mismatch throws.

**No self-update is applied automatically.** The user downloads the zip and replaces the folder manually. Unpinned `main` branches are never downloaded or executed.

---

## Configuration

The state directory defaults to `%ProgramData%\WinForge` and contains:

```text
%ProgramData%\WinForge\
├── logs\      winforge-YYYYMMDD.log
├── runs\      <RunId>.json
├── backups\   per-run state snapshots
└── updates\   downloaded and verified releases
```

The directory is ACL'd on creation: Administrators and SYSTEM full control, Users read-only. It is created by the installer or the first elevated run; non-elevated runs fall back to `%LOCALAPPDATA%\WinForge\` for read-only operations.

Override with `-StateRoot <path>`. Portable mode is detected if a `state` folder exists next to `WinForge.ps1`; relative paths are used.

---

## Building and testing

Pester 5.5+ and PSScriptAnalyzer are required.

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force

# Static analysis
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./packaging/psscriptanalyzer.psd1 -Severity Error,Warning

# Catalog + Pester + parse check
./packaging/check.ps1

# Pester only
Invoke-Pester -Path ./Tests -Output Detailed

# Build a release zip (writes dist/WinForge-<version>.zip and SHA256SUMS.txt)
./packaging/build.ps1 -Version 0.2.0
```

CI runs on `windows-latest` and executes the same steps for every push and pull request (`.github/workflows/ci.yml`).

**Do not run `Apply` or `Undo` integration tests against your host.** All Pester tests mock the adapters; real round-trip tests belong in a disposable Windows 11 VM.

---

## Known limitations

The following are real and worth knowing before you rely on WinForge:

- **Launcher.** `WinForge.bat` uses `net session` to detect elevation, which fails if the Server service is stopped. CLI arguments are forwarded through `cmd /k` on self-elevation; if you pass unquoted `&` or `|` on the command line, the elevated `cmd` will interpret them. For elevated CLI use, open an elevated prompt and run `WinForge.ps1` directly.
- **GUI.** The apply timer's tick handler reads controls that may go out of scope when the click handler returns. On some systems the apply result may not appear, or the window may exit without an error. If that happens, use the CLI — every operation is available there.
- **Undo.** Undo does not currently show a preview before restoring, does not verify the restored state, and overwrites the run's `Status` field. The captured snapshot is used, so the actual restore is correct; the record is less informative than it should be.
- **Undo with an invalid catalog.** If `tweaks.json` becomes invalid (a bad update, a removed tweak), undo currently refuses to run because it validates the catalog first. Keep a backup of `Catalog/tweaks.json`.
- **Appx.** Removal is per-user only. Provisioned packages and other users are unaffected. Reinstalls may not match the original version.
- **HKCU tweaks.** Apply to the account that runs WinForge. The tool does not target other users or the default profile.
- **Registry rollback edge cases.** `REG_DWORD` values above `2147483647` and exact typed comparison for `REG_MULTI_SZ` / `REG_BINARY` are not fully handled; treat those as `NotReversible` and remove the tweak from your profile if you need them.
- **Deploy.** `FirstLogonCommands` runs in the user token and can fail if the first-run path is interrupted. The `$OEM$` hook is recommended but not generated by default.
- **Monitor.** The `Class` column is `Unclassified` — no reverse DNS or heuristic labeling. Export and compare functions are not wired to the CLI or GUI.
- **Installer.** Install history is not persisted. Chocolatey must be installed manually.
- **License.** `LICENSE` is currently a placeholder. Do not redistribute without inserting a real license.
- **Not affiliated with Microsoft.** WinForge is an independent project. It does not bundle, redistribute, or activate Windows.

If any of these matter for your use case, open an issue before applying.

---

## Documentation

- `docs/architecture.md` — front ends, engine, adapters, state model
- `docs/security.md` — threat model, ACLs, the Expert gate, what the catalog cannot do
- `docs/catalog.md` — schema, allowed operation types, validation rules
- `docs/integration-matrix.md` — feature-by-feature migration status

---

## Contributing

Tweak PR checklist:

1. `SourceUrl` points at Microsoft documentation or reproducible test evidence.
2. `Risk` is correct — `Safe`, `Caution`, or `Danger`. `Danger` means it weakens security or breaks a common workflow, and it must not appear in any profile.
3. `Reversible` and `Undo.Strategy` are declared. `partial` requires a `Notes` field explaining what is not reversible.
4. The registry kind is exact — do not guess between `String` and `ExpandString`.
5. Tested on at least Windows 11 Home and Pro. Note the builds in the PR.
6. `.\WinForge.ps1 -Command ValidateCatalog` passes.
7. `Invoke-Pester -Path ./Tests` passes.

See `CONTRIBUTING.md` for the full guide and `SECURITY.md` for private disclosure.

---

## License

`LICENSE` in this repository is a placeholder. Before redistributing WinForge — or any file in `Catalog/` — insert a real license and record attribution for any code or idea adapted from other projects.

---

## Disclaimer

WinForge changes real system state. Use it on machines you control or are authorized to manage. Back up your system before applying changes you are not certain about. The authors are not responsible for damage caused by misuse or by Windows behaviour that differs from the tested builds.