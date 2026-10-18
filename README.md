# WinForge

Preview-first Windows debloat, privacy and app-install toolkit with a shared engine,
a data-driven catalog, and per-operation rollback.

## Status

Scaffold. Engine, adapters, catalog validation, Expert gate and Pester tests are in place.
Debloat/privacy migration, installer, deploy and updates are skeletons (see `docs/integration-matrix.md`).

## Quick start

    .\WinForge.ps1 -Command ValidateCatalog
    .\WinForge.ps1 -Command Dashboard
    .\WinForge.ps1 -Command Preview -Profile Minimal
    .\WinForge.ps1 -Command Apply   -Profile Minimal      # requires elevation
    .\WinForge.ps1 -Command History
    .\WinForge.ps1 -Command Undo    -RunId <id>

Danger tweaks additionally require `-Expert -TypedConfirmation <tweak-id>`.

## Tests

    Install-Module Pester -RequiredVersion 5.6.1 -Scope CurrentUser -Force -SkipPublisherCheck
    Install-Module PSScriptAnalyzer -RequiredVersion 1.22.0 -Scope CurrentUser -Force
    .\packaging\check.ps1      # analyzer, catalog validation and Pester; non-zero exit on failure

Tests mock every adapter that changes the system; they never touch the real registry,
services, tasks or packages. Real apply/undo round trips still need a Windows client VM.

## Build

    .\packaging\build.ps1 -Version 0.1.0