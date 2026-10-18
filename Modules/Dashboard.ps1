function Show-WinForgeDashboard {
    param($Context)
    $sys = Get-WinForgeSystemInfo
    $providers = @()
    if (Get-Command winget -ErrorAction SilentlyContinue) { $providers += 'winget' }
    if (Get-Command choco  -ErrorAction SilentlyContinue) { $providers += 'choco' }
    $last = Get-WinForgeHistory -Context $Context | Select-Object -First 1
    $posture = Get-WinForgeSecurityPosture

    Write-Host "WinForge $($Context.Version)" -ForegroundColor Cyan
    Write-Host ("  Build      {0}" -f $sys.Build)
    Write-Host ("  Edition    {0} ({1})" -f $sys.Edition, $sys.EditionId)
    Write-Host ("  Arch       {0}" -f $sys.Arch)
    Write-Host ("  Managed    {0}" -f $(if ($sys.Managed) { "yes ($($sys.ManagedReason)); only Safe tweaks apply" } else { 'no' }))
    Write-Host ("  Elevated   {0}" -f $sys.Elevated)
    Write-Host ("  Providers  {0}" -f $(if ($providers) { $providers -join ', ' } else { 'none' }))
    Write-Host ("  State root {0}" -f $Context.StateRoot)
    Write-Host ("  Last run   {0}" -f $(if ($last) { "$($last.RunId) applied=$($last.Applied) failed=$($last.Failed) restored=$($last.Restored)" } else { 'none' }))
    Write-Host '  Security' -ForegroundColor Cyan
    $posture.PSObject.Properties | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Name, $_.Value) }
}

function Get-WinForgeTweakStatusText {
    param($Tweak, $SystemInfo)
    $compat = Test-TweakCompatibility -Tweak $Tweak -SystemInfo $SystemInfo
    if (-not $compat.Supported) { return "unsupported: $($compat.Reason)" }
    if (@($Tweak.Targets | Where-Object { $_.Type -eq 'OptionalFeature' }).Count -gt 0 -and -not $SystemInfo.Elevated) { return 'unknown (run elevated to read optional features)' }
    if (Test-TweakTargets -Tweak $Tweak) { return 'applied' }
    return 'not applied'
}

function Show-WinForgeStatus {
    param($Context, [string[]] $TweakId, [Alias('Profile')] [string] $ProfileName)
    $catalog = Get-WinForgeCatalog -Context $Context
    $sys = Get-WinForgeSystemInfo
    $ids = @()
    if ($ProfileName) { $ids += (Get-WinForgeProfile -Name $ProfileName -Context $Context).TweakIds }
    if ($TweakId) { $ids += $TweakId }
    if (-not $ids) { $ids = $catalog.tweaks.Id }
    foreach ($id in ($ids | Select-Object -Unique)) {
        $t = Get-WinForgeTweak -Id $id -Context $Context -Catalog $catalog
        $text = if (-not $t) { 'unknown tweak ID' } else { Get-WinForgeTweakStatusText -Tweak $t -SystemInfo $sys }
        Write-Host ("  {0,-45} {1}" -f $id, $text)
    }
}
