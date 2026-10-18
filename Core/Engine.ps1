$script:UndoableStatuses = @('Applying','AppliedVerified','AwaitingRestart','Partial','VerifyFailed')

function Resolve-WinForgeTweaks {
    param([string[]] $TweakId, [Alias('Profile')] [string] $ProfileName, $Context, $Catalog)
    $ids = New-Object System.Collections.Generic.List[string]
    if ($ProfileName) {
        (Get-WinForgeProfile -Name $ProfileName -Context $Context).TweakIds | ForEach-Object { $ids.Add($_) }
    }
    if ($TweakId) { foreach ($t in $TweakId) { $ids.Add($t) } }
    $unique = @($ids | Select-Object -Unique)
    if (-not $unique) { throw 'No tweaks selected.' }

    $tweaks = @()
    foreach ($id in $unique) {
        $tw = Get-WinForgeTweak -Id $id -Context $Context -Catalog $Catalog
        if (-not $tw) { throw "Unknown tweak ID '$id'." }
        $tweaks += $tw
    }
    return $tweaks
}

function Test-TargetIdentity {
    # True when two targets address the same object, ignoring the desired value.
    param($A, $B)
    foreach ($f in 'Type','Hive','Path','Name') {
        if ([string](Get-TweakProperty $A $f) -ne [string](Get-TweakProperty $B $f)) { return $false }
    }
    return $true
}

function Invoke-WinForgeOperation {
    [CmdletBinding()]
    param(
        [string[]] $TweakId, [Alias('Profile')] [string] $ProfileName,
        [switch] $Preview, [switch] $Expert,
        # -Force means "the front end has shown the preview and the user confirmed".
        # The CLI prompts, the GUI and wizard show a Yes/No dialog, then pass -Force.
        [switch] $Force,
        [string] $TypedConfirmation, $Context,
        # Optional synchronized hashtable; when .Cancelled becomes true the run stops at
        # the next tweak boundary (never mid-tweak) and the rest are recorded Cancelled.
        $CancelToken
    )

    Assert-WinForgeCatalog -Context $Context
    $catalog = Get-WinForgeCatalog -Context $Context
    $tweaks  = Resolve-WinForgeTweaks -TweakId $TweakId -Profile $ProfileName -Context $Context -Catalog $catalog
    $sys     = Get-WinForgeSystemInfo
    $plan    = New-OperationPlan -Tweaks $tweaks -SystemInfo $sys

    if ($Preview) { Format-OperationPlan -Plan $plan; return $plan }
    if (-not $Context.Elevated) { throw 'Administrator privileges are required to apply changes.' }
    if (-not $Force) { throw 'Apply requires confirmation: review the preview, then pass -Force (CLI) or confirm in the GUI.' }

    $record = [pscustomobject]@{
        RunId = New-WinForgeRunId; StartedUtc = [DateTime]::UtcNow.ToString('o'); FinishedUtc = $null
        WinForgeVersion = $Context.Version; State = 'InProgress'
        Windows = @{ Build = $sys.Build; Edition = $sys.Edition; EditionId = $sys.EditionId; Arch = $sys.Arch }
        Elevated = $Context.Elevated; Profile = $ProfileName; Tweaks = @(); Undo = @()
    }
    Save-RunRecord -Context $Context -Record $record | Out-Null
    Write-WinForgeLog -Message "Run $($record.RunId) started ($(@($tweaks).Count) tweak(s))"
    $results = @()

    foreach ($t in $tweaks) {
        $entry = $plan | Where-Object { $_.Id -eq $t.Id } | Select-Object -First 1
        $row = [pscustomobject]@{ Id = $t.Id; Status = ''; Reason = ''; UndoStrategy = $t.Undo.Strategy; Before = $null; After = $null; UndoStatus = $null; UndoUtc = $null }

        if ($CancelToken -and $CancelToken['Cancelled']) { $row.Status = 'Cancelled'; $row.Reason = 'Run cancelled before this tweak' }
        elseif (-not $entry.Supported) { $row.Status = 'Skipped'; $row.Reason = $entry.Reason }
        elseif (Test-TweakTargets -Tweak $t) { $row.Status = 'AlreadyApplied'; $row.Before = $entry.Before; $row.After = $t.Targets }
        else {
            try { Assert-OperationAuthorized -Tweak $t -Expert:$Expert -TypedConfirmation $TypedConfirmation }
            catch { $row.Status = 'Blocked'; $row.Reason = $_.Exception.Message }
        }

        if ($row.Status) {
            $record.Tweaks += $row; Save-RunRecord -Context $Context -Record $record | Out-Null
            $results += [pscustomobject]@{ Id = $row.Id; Status = $row.Status; Reason = $row.Reason }
            Write-WinForgeLog -Level $(if ($row.Status -eq 'Blocked') { 'Warn' } else { 'Info' }) -Message "$($t.Id): $($row.Status) $($row.Reason)"
            continue
        }

        # Persist the captured state before touching anything, so a crash or Ctrl+C
        # mid-tweak still leaves an undoable record.
        $row.Status = 'Applying'; $row.Before = $entry.Before; $row.After = $t.Targets
        $record.Tweaks += $row; Save-RunRecord -Context $Context -Record $record | Out-Null

        $applied = @(); $errors = @()
        for ($i = 0; $i -lt @($t.Targets).Count; $i++) {
            try { Invoke-TargetApply -Target $t.Targets[$i]; $applied += $i }
            catch { $errors += $_.Exception.Message; Write-WinForgeLog -Level Error -Message "$($t.Id): apply failed: $($_.Exception.Message)"; break }
        }

        if ($errors.Count -gt 0 -and $applied.Count -gt 0) {
            # Keep tweaks atomic: undo the targets that did change, newest first.
            $rollbackErrors = @()
            foreach ($i in ($applied | Sort-Object -Descending)) {
                try { Restore-TargetSnapshot -Target $t.Targets[$i] -Snapshot @($entry.Before)[$i] }
                catch { $rollbackErrors += $_.Exception.Message }
            }
            if ($rollbackErrors.Count -eq 0) { $row.Status = 'RolledBack'; $row.Reason = "Apply failed and was rolled back: $($errors -join '; ')" }
            else { $row.Status = 'Partial'; $row.Reason = "Apply failed; rollback also failed: $($rollbackErrors -join '; ')" }
        } elseif ($errors.Count -gt 0) {
            $row.Status = 'Failed'; $row.Reason = $errors -join '; '
        } elseif (Test-TweakTargets -Tweak $t) {
            $row.Status = if ($t.NeedsRestart) { 'AwaitingRestart' } else { 'AppliedVerified' }
        } else {
            $row.Status = 'VerifyFailed'; $row.Reason = 'Change was written but the new state could not be verified.'
        }

        Save-RunRecord -Context $Context -Record $record | Out-Null
        Write-WinForgeLog -Level $(if ($row.Status -in @('AppliedVerified','AwaitingRestart')) { 'Info' } else { 'Error' }) -Message "$($t.Id): $($row.Status) $($row.Reason)"
        $results += [pscustomobject]@{ Id = $row.Id; Status = $row.Status; Reason = $row.Reason }
    }

    $record.State = if (@($record.Tweaks | Where-Object Status -eq 'Cancelled').Count) { 'Cancelled' } else { 'Completed' }
    $record.FinishedUtc = [DateTime]::UtcNow.ToString('o')
    Save-RunRecord -Context $Context -Record $record | Out-Null
    Write-WinForgeLog -Message "Run $($record.RunId) completed"
    return $results
}

function Get-WinForgeUndoPlan {
    # Decides, per recorded tweak, whether and how it can be restored, and pairs the live
    # state with the state that would be restored. Reads only.
    #
    # Target source: when the catalog is valid and still defines the tweak, the recorded
    # targets must match it (protects against tampered records and catalog drift). When
    # the catalog is broken or the tweak was removed, the recorded targets are used, but
    # only from a protected state folder (or with -AllowRecordedTargets) and only after
    # the same per-target validation the catalog gets. A bad catalog never blocks Undo.
    param($Context, [string] $RunId, [string[]] $TweakId, [switch] $AllowRecordedTargets)

    $record = Get-RunRecord -Context $Context -RunId $RunId
    $check = Test-WinForgeCatalog -Context $Context
    $catalog = if ($check.Valid) { Get-WinForgeCatalog -Context $Context } else { $null }
    $trustRecord = [bool]$AllowRecordedTargets -or [bool](Get-TweakProperty $Context 'StateProtected')
    $kinds = @('DWord','QWord','String','ExpandString','MultiString','Binary')

    $entries = @($record.Tweaks)
    [array]::Reverse($entries)
    $plan = @()
    foreach ($entry in $entries) {
        if ($TweakId -and ($TweakId -notcontains $entry.Id)) { continue }
        # Older records overwrote Status with 'Restored'; newer ones keep Status and set UndoStatus.
        $undone = (Get-TweakProperty $entry 'UndoStatus') -eq 'Restored' -or $entry.Status -eq 'Restored'
        if ($undone -or $entry.Status -notin $script:UndoableStatuses) { continue }

        $item = [pscustomobject]@{ Id = $entry.Id; Action = 'Restore'; Source = 'catalog'; Reason = ''; Targets = @(); Before = @($entry.Before); Current = @() }
        $recorded = @($entry.After)
        if (-not $entry.Before -or -not $entry.After) { $item.Action = 'Skip'; $item.Reason = 'No captured state'; $plan += $item; continue }

        $t = if ($catalog) { Get-WinForgeTweak -Id $entry.Id -Catalog $catalog } else { $null }
        $strategy = Get-TweakProperty $entry 'UndoStrategy'
        if (-not $strategy -and $t) { $strategy = $t.Undo.Strategy }
        if (@($recorded | Where-Object { $_.Type -eq 'Appx' }).Count) { $strategy = 'ReinstallAppx' }
        if ($strategy -and $strategy -ne 'RestoreCapturedState') {
            $item.Action = 'NotReversible'
            $item.Reason = if ($strategy -eq 'ReinstallAppx') { 'Removed apps must be reinstalled from the Microsoft Store' } else { "Undo strategy is $strategy" }
            $plan += $item; continue
        }

        $errs = New-Object System.Collections.Generic.List[string]
        foreach ($tg in $recorded) { Test-WinForgeTarget -Target $tg -Owner $entry.Id -Errors $errs }
        if ($recorded.Count -ne $item.Before.Count) { $errs.Add('target and snapshot counts differ') }
        for ($i = 0; $i -lt [Math]::Min($recorded.Count, $item.Before.Count); $i++) {
            if ($recorded[$i].Type -eq 'Registry' -and (Get-TweakProperty $item.Before[$i] 'Existed') -and $kinds -notcontains (Get-TweakProperty $item.Before[$i] 'Kind')) { $errs.Add('snapshot has an invalid registry kind') }
        }
        if ($errs.Count) { $item.Action = 'Refuse'; $item.Reason = "Run record failed validation: $($errs -join '; ')"; $plan += $item; continue }

        if ($t) {
            $targets = @($t.Targets)
            $same = $targets.Count -eq $recorded.Count
            for ($i = 0; $same -and $i -lt $targets.Count; $i++) { $same = Test-TargetIdentity $targets[$i] $recorded[$i] }
            if (-not $same) { $item.Action = 'Refuse'; $item.Reason = 'Run record does not match the catalog targets'; $plan += $item; continue }
            $item.Targets = $targets
        } elseif ($trustRecord) {
            $item.Targets = $recorded; $item.Source = 'run record'
            $item.Reason = if ($catalog) { 'Tweak no longer in catalog; using the targets recorded at apply time' } else { 'Catalog is invalid; using the targets recorded at apply time' }
        } else {
            $item.Action = 'Refuse'
            $item.Reason = 'Catalog cannot confirm these targets and the state folder is not protected; rerun with -AllowRecordedTargets after checking the run record'
            $plan += $item; continue
        }
        $item.Current = @($item.Targets | ForEach-Object { Get-TargetSnapshot -Target $_ })
        $plan += $item
    }
    return $plan
}

function Get-WinForgeUndoPlanText {
    param($Plan)
    $lines = @()
    foreach ($p in $Plan) {
        if ($p.Action -ne 'Restore') { $lines += ("{0,-42} {1}: {2}" -f $p.Id, $p.Action.ToUpper(), $p.Reason); continue }
        for ($i = 0; $i -lt @($p.Targets).Count; $i++) {
            $tg = @($p.Targets)[$i]
            $lines += ("{0,-42} {1} -> restore {2}" -f $p.Id, (Format-TargetSnapshot -Target $tg -Snapshot @($p.Current)[$i]), (Format-TargetSnapshot -Target $tg -Snapshot @($p.Before)[$i]))
        }
        if ($p.Source -ne 'catalog') { $lines += ("{0,-42} NOTE: {1}" -f $p.Id, $p.Reason) }
    }
    return $lines
}

function Invoke-WinForgeUndo {
    param($Context, [string] $RunId, [string[]] $TweakId, [switch] $AllowRecordedTargets, [switch] $Preview)
    $plan = Get-WinForgeUndoPlan -Context $Context -RunId $RunId -TweakId $TweakId -AllowRecordedTargets:$AllowRecordedTargets
    if ($Preview) { return $plan }
    if (-not $Context.Elevated) { throw 'Administrator privileges are required to undo changes.' }

    $record = Get-RunRecord -Context $Context -RunId $RunId
    $results = @()
    foreach ($p in $plan) {
        if ($p.Action -ne 'Restore') {
            $st = switch ($p.Action) { 'Skip' { 'Skipped' } 'Refuse' { 'Refused' } default { 'NotReversible' } }
            $results += [pscustomobject]@{ Id = $p.Id; Status = $st; Reason = $p.Reason }
            continue
        }
        $entry = @($record.Tweaks | Where-Object { $_.Id -eq $p.Id })[-1]
        $targets = @($p.Targets); $before = @($p.Before)
        $status = 'Restored'; $reason = ''
        try {
            for ($i = $targets.Count - 1; $i -ge 0; $i--) { Restore-TargetSnapshot -Target $targets[$i] -Snapshot $before[$i] }
            # Read back every target: a restore is only reported as done when the live
            # state matches what was captured before the original change.
            $diff = @()
            for ($i = 0; $i -lt $targets.Count; $i++) {
                $now = Get-TargetSnapshot -Target $targets[$i]
                if (-not (Test-SnapshotEquals -Target $targets[$i] -Expected $before[$i] -Actual $now)) {
                    $diff += "$($targets[$i].Name): now $(Format-TargetSnapshot -Target $targets[$i] -Snapshot $now), expected $(Format-TargetSnapshot -Target $targets[$i] -Snapshot $before[$i])"
                }
            }
            if ($diff) { $status = 'RestoreUnverified'; $reason = $diff -join '; ' }
        } catch {
            $status = 'Failed'; $reason = $_.Exception.Message
        }
        if ($p.Source -ne 'catalog') { $reason = (@($reason, 'source: run record') | Where-Object { $_ }) -join '; ' }

        # The original Status is kept; the undo outcome is recorded alongside it.
        foreach ($f in 'UndoStatus','UndoUtc','UndoReason') {
            if (-not $entry.PSObject.Properties[$f]) { $entry | Add-Member -NotePropertyName $f -NotePropertyValue $null }
        }
        $entry.UndoStatus = $status; $entry.UndoUtc = [DateTime]::UtcNow.ToString('o'); $entry.UndoReason = $reason
        $results += [pscustomobject]@{ Id = $p.Id; Status = $status; Reason = $reason }
        Write-WinForgeLog -Level $(if ($status -eq 'Restored') { 'Info' } else { 'Error' }) -Message "$($p.Id): undo $status $reason (run $RunId)"
    }

    if (-not $record.PSObject.Properties['Undo']) { $record | Add-Member -NotePropertyName Undo -NotePropertyValue @() }
    $record.Undo = @(@($record.Undo) | Where-Object { $_ }) + [pscustomobject]@{
        Utc = [DateTime]::UtcNow.ToString('o'); User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        TweakIds = $TweakId; Results = $results
    }
    Save-RunRecord -Context $Context -Record $record | Out-Null
    return $results
}
