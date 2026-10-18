function Get-WinForgeTweaksByCategory {
    param($Context, [string] $Category)
    $catalog = Get-WinForgeCatalog -Context $Context
    $items = if ($Category) { $catalog.tweaks | Where-Object { $_.Category -eq $Category } } else { $catalog.tweaks }
    return $items
}

function Get-WinForgeAppliedState {
    param($Context, [string[]] $TweakId)
    $catalog = Get-WinForgeCatalog -Context $Context
    $ids = if ($TweakId) { $TweakId } else { $catalog.tweaks.Id }
    foreach ($id in $ids) {
        $t = Get-WinForgeTweak -Id $id -Context $Context -Catalog $catalog
        if (-not $t) { throw "Unknown tweak ID '$id'." }
        [pscustomobject]@{ Id = $id; Applied = (Test-TweakTargets -Tweak $t) }
    }
}

function Show-WinForgeTweakList {
    param($Context, [string] $Category)
    $sys = Get-WinForgeSystemInfo
    foreach ($t in (Get-WinForgeTweaksByCategory -Context $Context -Category $Category)) {
        $compat = Test-TweakCompatibility -Tweak $t -SystemInfo $sys
        $needsElevation = @($t.Targets | Where-Object { $_.Type -eq 'OptionalFeature' }).Count -gt 0 -and -not $sys.Elevated
        # $null means "could not be read", not "not applied".
        $applied = if (-not $compat.Supported -or $needsElevation) { $null } else { Test-TweakTargets -Tweak $t }
        [pscustomobject]@{
            Id = $t.Id; Name = $t.Name; Category = $t.Category; Risk = $t.Risk; Reversible = $t.Reversible
            Applied = $applied; Supported = $compat.Supported
            Reason = if ($needsElevation) { 'Run elevated to read optional features' } else { $compat.Reason }
        }
    }
}
