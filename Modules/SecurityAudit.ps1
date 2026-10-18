function Get-WinForgeRegistryValueOrNull {
    param([string] $Path, [string] $Name)
    try {
        $p = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        if ($p.PSObject.Properties[$Name]) { return $p.$Name }
    } catch { Write-Verbose "$Path not readable: $($_.Exception.Message)" }
    return $null
}

function Get-WinForgeSecurityPosture {
    # Read-only. Each value says where it came from; 'Unavailable' means the API did not
    # answer (for example without elevation), not that the protection is off.
    $out = [ordered]@{}
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $out.DefenderRealTime = $mp.RealTimeProtectionEnabled
        # Passive/EDR Block mode means another antivirus is the active one.
        $out.DefenderMode = if ($mp.PSObject.Properties['AMRunningMode']) { $mp.AMRunningMode } else { 'Unavailable' }
        $out.TamperProtection = if ($mp.PSObject.Properties['IsTamperProtected']) { $mp.IsTamperProtected } else { 'Unavailable' }
    } catch { $out.DefenderRealTime = 'Unavailable'; $out.DefenderMode = 'Unavailable'; $out.TamperProtection = 'Unavailable' }

    try { $out.FirewallProfiles = ((Get-NetFirewallProfile -ErrorAction Stop) | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join '; ' }
    catch { $out.FirewallProfiles = 'Unavailable' }

    $ssPolicy = Get-WinForgeRegistryValueOrNull 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    $out.SmartScreenPolicy = if ($null -eq $ssPolicy) { 'Not set by policy' } else { "EnableSmartScreen=$ssPolicy (policy)" }
    $ssSetting = Get-WinForgeRegistryValueOrNull 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
    $out.SmartScreenSetting = if ($null -eq $ssSetting) { 'Not configured (Windows default applies)' } else { "$ssSetting (configured value; not a runtime check)" }

    try { $out.SystemDriveProtection = (Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus }
    catch { $out.SystemDriveProtection = 'Unavailable (requires admin / BitLocker cmdlets)' }

    return [pscustomobject]$out
}

function Show-WinForgeSecurityAudit {
    $p = Get-WinForgeSecurityPosture
    Write-Host 'Security posture (read-only)' -ForegroundColor Cyan
    $p.PSObject.Properties | ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.Name, $_.Value) }
    Write-Host '  Note: values marked Unavailable were not established by the API; they are not false.' -ForegroundColor DarkGray
}
