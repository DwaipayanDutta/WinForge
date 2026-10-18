#Requires -Version 5.1
<#
.SYNOPSIS
    Runs every WinForge check and exits non-zero if any fails: PSScriptAnalyzer
    (product and tests), catalog validation, and the Pester suite.
    Requires Pester 5.5+ and PSScriptAnalyzer to be importable.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = @()

Import-Module PSScriptAnalyzer
Import-Module Pester -MinimumVersion 5.5.0

Write-Host '== PSScriptAnalyzer (product)' -ForegroundColor Cyan
$product = @('WinForge.ps1','Core','Adapters','Modules','UI','packaging') | ForEach-Object { Join-Path $root $_ }
$findings = @($product | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings (Join-Path $PSScriptRoot 'psscriptanalyzer.psd1') })
$findings | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap
if ($findings.Count) { $failed += "PSScriptAnalyzer (product): $($findings.Count) finding(s)" }

Write-Host '== PSScriptAnalyzer (tests)' -ForegroundColor Cyan
$findings = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'Tests') -Recurse -Settings (Join-Path $PSScriptRoot 'psscriptanalyzer.tests.psd1'))
$findings | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap
if ($findings.Count) { $failed += "PSScriptAnalyzer (tests): $($findings.Count) finding(s)" }

Write-Host '== Catalog validation' -ForegroundColor Cyan
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'WinForge.ps1') ValidateCatalog -StateRoot (Join-Path ([IO.Path]::GetTempPath()) 'winforge-check-state')
if ($LASTEXITCODE -ne 0) { $failed += 'Catalog validation' }

Write-Host '== Pester' -ForegroundColor Cyan
$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $root 'Tests'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Normal'
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputPath = Join-Path $root 'dist\test-results.xml'
New-Item -ItemType Directory -Path (Join-Path $root 'dist') -Force | Out-Null
$r = Invoke-Pester -Configuration $cfg
if ($r.FailedCount -gt 0 -or $r.Result -ne 'Passed') { $failed += "Pester: $($r.FailedCount) failed" }

if ($failed) { Write-Host "FAILED: $($failed -join '; ')" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
