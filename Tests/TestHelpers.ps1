# Dot-sourced from each test file's BeforeAll. Loads the engine, adapters and modules
# (not the WinForms UI). Tests must never change the host: every adapter that writes is
# mocked, and registry tests use mocked providers, never real keys.
$script:WfRoot = Split-Path -Parent $PSScriptRoot
foreach ($f in @(
    'Core\Context.ps1','Core\Logging.ps1','Core\Catalog.ps1','Core\Compatibility.ps1',
    'Core\State.ps1','Core\Planner.ps1','Core\Authorization.ps1','Core\History.ps1',
    'Adapters\Registry.ps1','Adapters\Service.ps1','Adapters\Task.ps1','Adapters\Feature.ps1','Adapters\Appx.ps1',
    'Core\Engine.ps1',
    'Modules\Dashboard.ps1','Modules\Debloat.ps1','Modules\Privacy.ps1','Modules\Monitor.ps1',
    'Modules\SecurityAudit.ps1','Modules\Installer.ps1','Modules\Deploy.ps1','Modules\Updates.ps1'
)) { . (Join-Path $script:WfRoot $f) }

function New-WfTestTweak {
    # A minimal valid tweak; tests override fields to make it invalid.
    param([string] $Id = 'test-tweak', [string] $Risk = 'Safe', [object[]] $Targets)
    if (-not $Targets) { $Targets = @(@{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\WinForgeTest'; Name = 'X'; Kind = 'DWord'; Value = 1 }) }
    return [ordered]@{
        Id = $Id; Name = 'Test tweak'; Description = 'A tweak used only by tests.'; Category = 'Privacy'
        Risk = $Risk; Reversible = 'full'; NeedsRestart = $false; Targets = $Targets
        Verification = @{ Type = 'RegistryEquals' }; Undo = @{ Strategy = 'RestoreCapturedState' }
    }
}

function New-WfTestCatalog {
    # Writes tweaks.json / profiles.json (and optionally apps.json) to a fresh folder.
    param([object[]] $Tweaks, [object[]] $Profiles = @(), [object[]] $Apps)
    $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    ConvertTo-Json -InputObject ([ordered]@{ version = 1; tweaks = @($Tweaks) }) -Depth 12 | Set-Content (Join-Path $dir 'tweaks.json') -Encoding UTF8
    ConvertTo-Json -InputObject ([ordered]@{ version = 1; profiles = @($Profiles) }) -Depth 12 | Set-Content (Join-Path $dir 'profiles.json') -Encoding UTF8
    if ($Apps) {
        ConvertTo-Json -InputObject ([ordered]@{ version = 1; apps = @($Apps) }) -Depth 12 | Set-Content (Join-Path $dir 'apps.json') -Encoding UTF8
        ConvertTo-Json -InputObject ([ordered]@{ version = 1; bundles = @() }) -Depth 12 | Set-Content (Join-Path $dir 'bundles.json') -Encoding UTF8
    }
    return $dir
}

function New-WfTestContext {
    param([string] $CatalogRoot, [switch] $Elevated)
    $ctx = New-WinForgeContext -StateRoot (Join-Path $TestDrive ('state-' + [guid]::NewGuid().ToString('N')))
    if ($CatalogRoot) { $ctx.CatalogRoot = $CatalogRoot }
    $ctx.Elevated = [bool]$Elevated
    Initialize-WinForgeLog -Context $ctx
    return $ctx
}

function Get-WfTestSystem {
    param([string] $Edition = 'Pro', [bool] $Managed = $false, [bool] $Elevated = $true)
    [pscustomobject]@{ Build = 26100; Edition = $Edition; EditionId = 'Professional'; Arch = 'x64'; Managed = $Managed; ManagedReason = ''; Elevated = $Elevated }
}
