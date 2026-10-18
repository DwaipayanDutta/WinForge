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
        [string] $TypedConfirmation, $Context
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
        $row = [pscustomobject]@{ Id = $t.Id; Status = ''; Reason = ''; Before = $null; After = $null }

        if (-not $entry.Supported) { $row.Status = 'Skipped'; $row.Reason = $entry.Reason }
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

    $record.State = 'Completed'; $record.FinishedUtc = [DateTime]::UtcNow.ToString('o')
    Save-RunRecord -Context $Context -Record $record | Out-Null
    Write-WinForgeLog -Message "Run $($record.RunId) completed"
    return $results
}

function Invoke-WinForgeUndo {
    param($Context, [string] $RunId, [string[]] $TweakId)
    if (-not $Context.Elevated) { throw 'Administrator privileges are required to undo changes.' }
    Assert-WinForgeCatalog -Context $Context
    $record  = Get-RunRecord -Context $Context -RunId $RunId
    $catalog = Get-WinForgeCatalog -Context $Context
    $results = @()

    $entries = @($record.Tweaks)
    [array]::Reverse($entries)
    foreach ($entry in $entries) {
        if ($TweakId -and ($TweakId -notcontains $entry.Id)) { continue }
        if ($entry.Status -notin $script:UndoableStatuses) { continue }
        $before = @($entry.Before)
        if (-not $entry.Before) { $results += [pscustomobject]@{ Id = $entry.Id; Status = 'Skipped'; Reason = 'No captured state' }; continue }

        $t = Get-WinForgeTweak -Id $entry.Id -Context $Context -Catalog $catalog
        if (-not $t) { $results += [pscustomobject]@{ Id = $entry.Id; Status = 'Skipped'; Reason = 'Tweak no longer in catalog; restore manually from the run record' }; continue }
        if ($t.Undo.Strategy -ne 'RestoreCapturedState') {
            $results += [pscustomobject]@{ Id = $entry.Id; Status = 'NotReversible'; Reason = $t.Undo.Strategy }
            continue
        }

        # Only restore onto targets the current catalog also defines. A record whose
        # targets differ (catalog update, or a tampered file) is refused, never trusted.
        $targets = @($t.Targets); $recorded = @($entry.After)
        $mismatch = ($targets.Count -ne $recorded.Count) -or ($targets.Count -ne $before.Count)
        for ($i = 0; -not $mismatch -and $i -lt $targets.Count; $i++) {
            if (-not (Test-TargetIdentity $targets[$i] $recorded[$i])) { $mismatch = $true }
            if ($targets[$i].Type -eq 'Registry' -and (Get-TweakProperty $before[$i] 'Existed') -and
                @('DWord','QWord','String','ExpandString','MultiString','Binary') -notcontains (Get-TweakProperty $before[$i] 'Kind')) { $mismatch = $true }
        }
        if ($mismatch) { $results += [pscustomobject]@{ Id = $entry.Id; Status = 'Refused'; Reason = 'Run record does not match the catalog targets' }; continue }

        try {
            for ($i = $targets.Count - 1; $i -ge 0; $i--) {
                Restore-TargetSnapshot -Target $targets[$i] -Snapshot $before[$i]
            }
            $entry.Status = 'Restored'
            $results += [pscustomobject]@{ Id = $entry.Id; Status = 'Restored'; Reason = '' }
            Write-WinForgeLog -Message "$($entry.Id): restored from run $RunId"
        } catch {
            $results += [pscustomobject]@{ Id = $entry.Id; Status = 'Failed'; Reason = $_.Exception.Message }
            Write-WinForgeLog -Level Error -Message "$($entry.Id): undo failed: $($_.Exception.Message)"
        }
    }

    if (-not $record.PSObject.Properties['Undo']) { $record | Add-Member -NotePropertyName Undo -NotePropertyValue @() }
    $record.Undo = @(@($record.Undo) | Where-Object { $_ }) + [pscustomobject]@{ Utc = [DateTime]::UtcNow.ToString('o'); Results = $results }
    Save-RunRecord -Context $Context -Record $record | Out-Null
    return $results
}
