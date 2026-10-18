function ConvertTo-ServiceStartType {
    # Win32_Service reports 'Auto'; Set-Service and the catalog use 'Automatic'.
    param([string] $StartMode)
    if ($StartMode -eq 'Auto') { return 'Automatic' }
    return $StartMode
}

function Invoke-ScConfig {
    param([string] $Name, [string] $Start)
    $out = & sc.exe config $Name start= $Start 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config $Name start= $Start failed ($LASTEXITCODE): $out" }
}

function Get-ServiceState {
    param($Target)
    if ($Target.Name -notmatch '^[A-Za-z0-9_.-]{1,80}$') { throw "Invalid service name '$($Target.Name)'" }
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Target.Name)'" -ErrorAction SilentlyContinue
    if (-not $svc) { return [pscustomobject]@{ Existed = $false; StartMode = $null; Delayed = $false } }
    $delayed = [bool]($svc.PSObject.Properties['DelayedAutoStart'] -and $svc.DelayedAutoStart)
    return [pscustomobject]@{ Existed = $true; StartMode = (ConvertTo-ServiceStartType $svc.StartMode); Delayed = $delayed }
}

function Set-ServiceStartType {
    param($Target)
    Set-Service -Name $Target.Name -StartupType $Target.Value -ErrorAction Stop
}

function Restore-ServiceState {
    param($Target, $Snapshot)
    if (-not $Snapshot.Existed) { return }
    $mode = ConvertTo-ServiceStartType $Snapshot.StartMode
    $delayed = $Snapshot.PSObject.Properties['Delayed'] -and $Snapshot.Delayed
    if ($mode -eq 'Automatic' -and $delayed) { Invoke-ScConfig -Name $Target.Name -Start 'delayed-auto' }
    elseif ($mode -in @('Boot','System')) { Invoke-ScConfig -Name $Target.Name -Start $mode.ToLower() }
    else { Set-Service -Name $Target.Name -StartupType $mode -ErrorAction Stop }
}

function Test-ServiceTarget {
    param($Target)
    $s = Get-ServiceState -Target $Target
    return ($s.Existed -and $s.StartMode -eq $Target.Value)
}
