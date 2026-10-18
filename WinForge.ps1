<#
.SYNOPSIS
    WinForge: preview-first Windows debloat, privacy and app-install toolkit.

.DESCRIPTION
    Every change goes through one engine: validate catalog -> check compatibility ->
    capture current state -> preview -> confirm -> apply -> verify -> record. Every run
    is recorded and can be undone per run or per tweak.

.PARAMETER Command
    Help, ValidateCatalog, Dashboard, Status, List, Privacy, Monitor, Audit, Preview,
    Apply, Undo, History, Install, Deploy, UpdateCheck, Gui, Wizard.

.PARAMETER Force
    Apply/Undo: skip the interactive confirmation (the preview is still printed).
    Install: actually install instead of a dry run. UpdateCheck: download and verify.

.EXAMPLE
    .\WinForge.ps1 Preview -Profile Recommended

.EXAMPLE
    .\WinForge.ps1 Apply -Profile Recommended

.EXAMPLE
    WinForge.bat Preview -Tweak taskbar-align-left,explorer-show-file-extensions

.EXAMPLE
    .\WinForge.ps1 Apply -Tweak danger-disable-print-spooler -Expert -TypedConfirmation danger-disable-print-spooler

.EXAMPLE
    .\WinForge.ps1 Undo -RunId 20261018T120000Z-1a2b3c
#>
# #Requires must come after the help block: placed first, it hides the help from Get-Help.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Help','ValidateCatalog','Status','Preview','Apply','Undo','History','Dashboard',
                 'List','Privacy','Monitor','Audit','Install','Deploy','UpdateCheck','Gui','Wizard')]
    [string] $Command = 'Help',

    [string[]] $Tweak,
    [Alias('Profile')] [string]   $ProfileName,
    [string]   $RunId,
    [string]   $Bundle,
    [string]   $OutFile,
    [switch]   $Expert,
    [switch]   $Force,
    [string]   $TypedConfirmation,
    [string]   $StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# powershell -File (used by WinForge.bat) passes "-Tweak a,b" as one string; split it.
if ($Tweak) { $Tweak = @($Tweak | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$script:Root = $PSScriptRoot
foreach ($f in @(
    'Core\Context.ps1','Core\Logging.ps1','Core\Catalog.ps1','Core\Compatibility.ps1',
    'Core\State.ps1','Core\Planner.ps1','Core\Authorization.ps1','Core\History.ps1',
    'Adapters\Registry.ps1','Adapters\Service.ps1','Adapters\Task.ps1','Adapters\Feature.ps1','Adapters\Appx.ps1',
    'Core\Engine.ps1',
    'Modules\Dashboard.ps1','Modules\Debloat.ps1','Modules\Privacy.ps1',
    'Modules\Monitor.ps1','Modules\SecurityAudit.ps1','Modules\Installer.ps1',
    'Modules\Deploy.ps1','Modules\Updates.ps1'
)) { . (Join-Path $Root $f) }

$ctx = New-WinForgeContext -StateRoot $StateRoot
Initialize-WinForgeLog -Context $ctx

function Confirm-WinForgeAction {
    param([string] $Prompt)
    if ($Force) { return $true }
    return ((Read-Host "$Prompt Type YES to continue") -ceq 'YES')
}

switch ($Command) {
    'Help'            { Get-Help (Join-Path $Root 'WinForge.ps1') -Full }
    'ValidateCatalog' {
        $r = Test-WinForgeCatalog -Context $ctx
        if ($r.Valid) { Write-Host 'Catalog OK' -ForegroundColor Green; exit 0 }
        $r.Errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }
    'Dashboard' { Show-WinForgeDashboard -Context $ctx }
    'Status'    { Show-WinForgeStatus -Context $ctx -TweakId $Tweak -Profile $ProfileName }
    'List'      { Show-WinForgeTweakList -Context $ctx | Format-Table -AutoSize }
    'Privacy'   { Show-WinForgePrivacySummary -Context $ctx }
    'Monitor'   { Get-WinForgeConnectionSnapshot | Format-Table -AutoSize }
    'Audit'     { Show-WinForgeSecurityAudit }
    'Preview'   {
        Invoke-WinForgeOperation -Context $ctx -TweakId $Tweak -Profile $ProfileName -Preview |
            Select-Object Id, Risk, Supported, Reason | Format-Table -AutoSize
    }
    'Apply'     {
        if (-not $ctx.Elevated) { throw 'Administrator privileges are required to apply changes. Run WinForge.bat.' }
        $plan = Invoke-WinForgeOperation -Context $ctx -TweakId $Tweak -Profile $ProfileName -Preview
        if (-not @($plan | Where-Object Supported)) { Write-Host 'Nothing to apply on this system.'; exit 0 }
        if (-not (Confirm-WinForgeAction 'Apply the changes listed above?')) { Write-Host 'Cancelled. Nothing was changed.'; exit 2 }
        $res = Invoke-WinForgeOperation -Context $ctx -TweakId $Tweak -Profile $ProfileName -Expert:$Expert -Force -TypedConfirmation $TypedConfirmation
        $res | Format-Table -AutoSize
        if (@($res | Where-Object { $_.Status -in @('Failed','Partial','VerifyFailed','RolledBack','Blocked') })) { exit 1 }
    }
    'Undo'      {
        if (-not $RunId) { throw 'Use -RunId <id>. See: .\WinForge.ps1 History' }
        $rec = Get-RunRecord -Context $ctx -RunId $RunId
        @($rec.Tweaks) | Where-Object { -not $Tweak -or $Tweak -contains $_.Id } | Select-Object Id, Status | Format-Table -AutoSize
        if (-not (Confirm-WinForgeAction "Restore the captured state for run $RunId?")) { Write-Host 'Cancelled. Nothing was changed.'; exit 2 }
        $res = Invoke-WinForgeUndo -Context $ctx -RunId $RunId -TweakId $Tweak
        $res | Format-Table -AutoSize
        if (@($res | Where-Object { $_.Status -in @('Failed','Refused') })) { exit 1 }
    }
    'History'   { Get-WinForgeHistory -Context $ctx | Format-Table -AutoSize }
    'Install'   {
        $bundleId = if ($Bundle) { $Bundle } else { 'Essentials' }
        if (-not $Force) { Write-Host 'Dry run. Add -Force to install.' -ForegroundColor Yellow }
        $res = Install-WinForgeBundle -Context $ctx -BundleId $bundleId -DryRun:(-not $Force)
        $res | Format-Table -AutoSize
        if (@($res | Where-Object { $_.Status -in @('Failed','NoProvider','InstalledUnverified') })) { exit 1 }
    }
    'Deploy'    {
        if (-not $OutFile) { throw 'Use -OutFile <path> for the autounattend.xml output.' }
        $p = if ($ProfileName) { $ProfileName } else { 'Recommended' }
        Invoke-WinForgeDeployModule -Context $ctx -OutFile $OutFile -Profile $p | Format-List
    }
    'UpdateCheck' { Invoke-WinForgeUpdateCheck -Context $ctx -Download:$Force | Format-List }
    'Gui'       {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
        . (Join-Path $Root 'UI\Runspace.ps1')
        . (Join-Path $Root 'UI\MainForm.ps1')
        Show-WinForgeMainForm -Context $ctx
    }
    'Wizard'    {
        Add-Type -AssemblyName Microsoft.VisualBasic, System.Windows.Forms
        . (Join-Path $Root 'UI\Wizard.ps1')
        Start-WinForgeWizard -Context $ctx
    }
}
