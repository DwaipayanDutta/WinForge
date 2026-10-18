function ConvertTo-FeatureBaseState {
    # DISM reports pending states until restart; treat them as the state they are heading to.
    param([string] $State)
    switch -Regex ($State) {
        '^(Disabled|DisablePending|DisabledWithPayloadRemoved)$' { return 'Disabled' }
        '^(Enabled|EnablePending)$'                              { return 'Enabled' }
        default                                                  { return $State }
    }
}

function Get-FeatureState {
    param($Target)
    $elevated = ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevated) { return [pscustomobject]@{ Existed = $null; State = 'requires elevation to read' } }
    try { $f = Get-WindowsOptionalFeature -Online -FeatureName $Target.Name -ErrorAction Stop }
    catch { $f = $null }
    if (-not $f) { return [pscustomobject]@{ Existed = $false; State = $null } }
    return [pscustomobject]@{ Existed = $true; State = $f.State.ToString() }
}

function Set-FeatureState {
    param($Target)
    if ($Target.Value -eq 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName $Target.Name -NoRestart -ErrorAction Stop | Out-Null }
    else { Enable-WindowsOptionalFeature -Online -FeatureName $Target.Name -NoRestart -ErrorAction Stop | Out-Null }
}

function Restore-FeatureState {
    param($Target, $Snapshot)
    if (-not $Snapshot.Existed) { return }
    if ((ConvertTo-FeatureBaseState $Snapshot.State) -eq 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName $Target.Name -NoRestart -ErrorAction Stop | Out-Null }
    else { Enable-WindowsOptionalFeature -Online -FeatureName $Target.Name -NoRestart -ErrorAction Stop | Out-Null }
}

function Test-FeatureTarget {
    param($Target)
    $s = Get-FeatureState -Target $Target
    return ([bool]$s.Existed -and (ConvertTo-FeatureBaseState $s.State) -eq $Target.Value)
}
