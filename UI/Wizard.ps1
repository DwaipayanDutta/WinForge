Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

function Read-WinForgeYesNo {
    param([string] $Prompt, [string] $Default)
    $a = ([Microsoft.VisualBasic.Interaction]::InputBox($Prompt, 'WinForge setup', $Default)).Trim().ToLower()
    if ($a -eq '') { throw 'Setup cancelled.' }
    if ($a -notin @('yes','no')) { throw "Please answer yes or no (got '$a')." }
    return ($a -eq 'yes')
}

function Start-WinForgeWizard {
    param($Context)

    $q1 = ([Microsoft.VisualBasic.Interaction]::InputBox('How aggressive should WinForge be? (Minimal / Recommended / Aggressive)', 'WinForge setup', 'Recommended')).Trim()
    if ($q1 -eq '') { return }
    if ($q1 -notin @('Minimal','Recommended','Aggressive')) { throw "Unknown profile '$q1'." }
    $installApps = Read-WinForgeYesNo 'Install the Essentials app bundle too? (yes/no)' 'yes'
    $openMonitor = Read-WinForgeYesNo 'Show current network connections after setup? (yes/no)' 'no'

    # Preview first: the user sees every change and every app before anything happens.
    $plan = Invoke-WinForgeOperation -Context $Context -Profile $q1 -Preview
    $text = "Profile ${q1}:`r`n" + ((Get-OperationPlanText -Plan $plan) -join "`r`n")
    if ($installApps) {
        $dry = Install-WinForgeBundle -Context $Context -BundleId 'Essentials' -DryRun
        $text += "`r`n`r`nApps:`r`n" + (($dry | ForEach-Object { "$($_.Id)  $($_.Status)" }) -join "`r`n")
    }
    if ([System.Windows.Forms.MessageBox]::Show("$text`r`n`r`nApply now?", 'WinForge setup', 'YesNo') -ne 'Yes') { return }

    $r = Invoke-WinForgeOperation -Context $Context -Profile $q1 -Force
    $appReport = if ($installApps) { Install-WinForgeBundle -Context $Context -BundleId 'Essentials' } else { @() }

    [void][System.Windows.Forms.MessageBox]::Show(
        (($r | Format-Table -AutoSize | Out-String) + "`r`nApps:`r`n" + ($appReport | Format-Table -AutoSize | Out-String)),
        'WinForge setup complete')

    if ($openMonitor) {
        $snap = Get-WinForgeConnectionSnapshot | Where-Object { $_.State -eq 'Established' } | Select-Object -First 40
        [void][System.Windows.Forms.MessageBox]::Show(($snap | Format-Table Process, RemoteAddress, RemotePort -AutoSize | Out-String), 'Established connections')
    }
}
