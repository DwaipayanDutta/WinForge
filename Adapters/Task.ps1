function Get-TaskState {
    param($Target)
    $task = Get-ScheduledTask -TaskPath $Target.Path -TaskName $Target.Name -ErrorAction SilentlyContinue
    if (-not $task) { return [pscustomobject]@{ Existed = $false; State = $null } }
    return [pscustomobject]@{ Existed = $true; State = $task.State.ToString() }
}

function Set-TaskState {
    param($Target)
    if ($Target.Value -eq 'Disabled') { Disable-ScheduledTask -TaskPath $Target.Path -TaskName $Target.Name -ErrorAction Stop | Out-Null }
    else { Enable-ScheduledTask -TaskPath $Target.Path -TaskName $Target.Name -ErrorAction Stop | Out-Null }
}

function Restore-TaskState {
    param($Target, $Snapshot)
    if (-not $Snapshot.Existed) { return }
    if ($Snapshot.State -eq 'Disabled') { Disable-ScheduledTask -TaskPath $Target.Path -TaskName $Target.Name -ErrorAction Stop | Out-Null }
    else { Enable-ScheduledTask -TaskPath $Target.Path -TaskName $Target.Name -ErrorAction Stop | Out-Null }
}

function Test-TaskTarget {
    param($Target)
    $s = Get-TaskState -Target $Target
    if (-not $s.Existed) { return $false }
    # An enabled task reports Ready, Running or Queued depending on timing.
    if ($Target.Value -eq 'Ready') { return ($s.State -ne 'Disabled') }
    return ($s.State -eq $Target.Value)
}
