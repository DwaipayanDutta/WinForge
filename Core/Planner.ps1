function Format-TargetDesired {
    param($Target)
    switch ($Target.Type) {
        'Registry'        { return "$($Target.Kind) $(@($Target.Value) -join ',')" }
        'Service'         { return "StartType $($Target.Value)" }
        'ScheduledTask'   { return "Task $($Target.Value)" }
        'OptionalFeature' { return "Feature $($Target.Value)" }
        'Appx'            { return 'Removed (current user)' }
        default           { return [string]$Target.Type }
    }
}

function Format-TargetSnapshot {
    param($Target, $Snapshot)
    $existed = Get-TweakProperty $Snapshot 'Existed'
    if ($null -eq $existed) { return "Unknown ($(Get-TweakProperty $Snapshot 'State'))" }
    if (-not $existed) { if ($Target.Type -eq 'Appx') { return 'Not installed' } else { return '(not present)' } }
    switch ($Target.Type) {
        'Registry'        { return "$($Snapshot.Kind) $(@($Snapshot.Value) -join ',')" }
        'Service'         { return "StartType $($Snapshot.StartMode)$(if (Get-TweakProperty $Snapshot 'Delayed') { ' (delayed)' })" }
        'ScheduledTask'   { return "Task $($Snapshot.State)" }
        'OptionalFeature' { return "Feature $($Snapshot.State)" }
        'Appx'            { return 'Installed' }
        default           { return '?' }
    }
}

function New-OperationPlan {
    param($Tweaks, $SystemInfo)

    $plan = @()
    foreach ($t in $Tweaks) {
        $compat = Test-TweakCompatibility -Tweak $t -SystemInfo $SystemInfo
        if ($compat.Supported) {
            $snapshots = @()
            foreach ($tg in $t.Targets) { $snapshots += (Get-TargetSnapshot -Target $tg) }
            # A service, task or feature that does not exist on this build cannot be
            # changed; report it as unsupported instead of failing at apply time.
            for ($i = 0; $i -lt $snapshots.Count; $i++) {
                if ($t.Targets[$i].Type -in @('Service','ScheduledTask','OptionalFeature') -and (Get-TweakProperty $snapshots[$i] 'Existed') -eq $false) {
                    $compat = [pscustomobject]@{ Supported = $false; Reason = "$($t.Targets[$i].Type) '$($t.Targets[$i].Name)' is not present on this system" }
                    break
                }
            }
        }
        if (-not $compat.Supported) {
            $plan += [pscustomobject]@{
                Id = $t.Id; Name = $t.Name; Risk = $t.Risk; Supported = $false
                Reason = $compat.Reason; Notes = (Get-TweakProperty $t 'Notes'); Before = $null; After = $null
            }
            continue
        }
        $plan += [pscustomobject]@{
            Id = $t.Id; Name = $t.Name; Risk = $t.Risk; Supported = $true
            Reason = ''; Notes = (Get-TweakProperty $t 'Notes'); Before = $snapshots; After = $t.Targets
            Reversible = (Get-TweakProperty $t 'Reversible'); UndoStrategy = (Get-TweakProperty (Get-TweakProperty $t 'Undo') 'Strategy')
        }
    }
    return $plan
}

function Get-OperationPlanText {
    # One line per target: "<id>  <current> -> <new>". Shared by the CLI, GUI and wizard.
    param($Plan)
    $lines = @()
    foreach ($p in $Plan) {
        if (-not $p.Supported) { $lines += ("{0,-42} SKIP: {1}" -f $p.Id, $p.Reason); continue }
        for ($i = 0; $i -lt @($p.Before).Count; $i++) {
            $a = @($p.After)[$i]
            $lines += ("{0,-42} {1} -> {2}" -f $p.Id, (Format-TargetSnapshot -Target $a -Snapshot @($p.Before)[$i]), (Format-TargetDesired -Target $a))
        }
        if ($p.Risk -eq 'Danger') { $lines += ("{0,-42} DANGER: requires -Expert -TypedConfirmation {0}" -f $p.Id) }
        if ($p.Notes) { $lines += ("{0,-42} NOTE: {1}" -f $p.Id, $p.Notes) }
        $rev = Get-TweakProperty $p 'Reversible'
        if ($rev -and $rev -ne 'full') {
            $how = switch (Get-TweakProperty $p 'UndoStrategy') {
                'ReinstallAppx' { 'WinForge cannot undo this: reinstall the app from the Microsoft Store (needs a network connection). Removal applies to the current user only; the app stays provisioned for new accounts.' }
                'Manual'        { 'WinForge cannot undo this automatically; see the tweak description for manual steps.' }
                default         { 'WinForge cannot undo this.' }
            }
            $lines += ("{0,-42} REVERSIBLE: {1}. {2}" -f $p.Id, $rev, $how)
        }
    }
    return $lines
}

function Format-OperationPlan {
    param($Plan)
    foreach ($line in (Get-OperationPlanText -Plan $Plan)) {
        $level = if ($line -match ' SKIP: | DANGER: | REVERSIBLE: ') { 'Warn' } else { 'Info' }
        Write-WinForgeLog -Level $level -Message $line
    }
}
