# Integration matrix

| Capability | Code | Status | Tests |
|---|---|---|---|
| Shared engine (validate, plan, confirm, apply, verify, record, undo) | `Core/Engine.ps1` | implemented | `Engine.Tests.ps1` (mocked adapters) |
| Catalog validation (data only, no code paths) | `Core/Catalog.ps1` | implemented | `Catalog.Tests.ps1` |
| Registry / service / task / feature adapters | `Adapters/*` | implemented | `Rollback.Tests.ps1` (mocked) |
| Appx removal | `Adapters/Appx.ps1` | current user only; undo is manual reinstall | none on a real image |
| Tweak catalog | `Catalog/tweaks.json` | 44 tweaks; Win11DebloatMinimal migration incomplete | validated in CI |
| Profiles | `Catalog/profiles.json` | Minimal / Recommended / Aggressive, no Danger tweaks | `Authorization.Tests.ps1` |
| Installer | `Modules/Installer.ps1` | winget + optional choco, dry run by default | `Installer.Tests.ps1` (mocked providers) |
| Monitor | `Modules/Monitor.ps1` | snapshot + compare; no host classification yet | none |
| Security audit | `Modules/SecurityAudit.ps1` | read-only | none |
| Deploy | `Modules/Deploy.ps1` | answer file only; `$OEM$` copy and disk layout not implemented | `Deploy.Tests.ps1` |
| Updates | `Modules/Updates.ps1` | check + download + SHA256; no signature, never applies | `Updates.Tests.ps1` (mocked network) |
| GUI / wizard | `UI/*` | preview, apply (background runspace), restore, monitor tabs | parse check only |

Not yet tested anywhere: real Apply -> Test -> Undo round trips on a client VM (see the
testing strategy in the roadmap). Unit tests mock every adapter that writes.
