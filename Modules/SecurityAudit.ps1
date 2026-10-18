function Get-WinForgeSecurityPosture {
    $out = [ordered]@{}
    try { $out.DefenderRealTime = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled }
    catch { $out.DefenderRealTime = 'Unavailable' }

    try { $out.FirewallProfiles = ((Get-NetFirewallProfile -ErrorAction Stop) | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join '; ' }
    catch { $out.FirewallProfiles = 'Unavailable' }

    try {
        $ss = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -ErrorAction Stop).EnableSmartScreen
        $out.SmartScreenPolicy = if ($null -eq $ss) { 'Not set by policy' } else { $ss }
    } catch { $out.SmartScreenPolicy = 'Not set by policy' }

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