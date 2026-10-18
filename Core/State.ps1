function Get-TargetSnapshot {
    param($Target)
    switch ($Target.Type) {
        'Registry'        { return Get-RegistryState  -Target $Target }
        'Service'         { return Get-ServiceState   -Target $Target }
        'ScheduledTask'   { return Get-TaskState      -Target $Target }
        'OptionalFeature' { return Get-FeatureState   -Target $Target }
        'Appx'            { return Get-AppxState      -Target $Target }
        default           { throw "Unknown target type '$($Target.Type)'" }
    }
}

function Restore-TargetSnapshot {
    param($Target, $Snapshot)
    switch ($Target.Type) {
        'Registry'        { Restore-RegistryState -Target $Target -Snapshot $Snapshot }
        'Service'         { Restore-ServiceState  -Target $Target -Snapshot $Snapshot }
        'ScheduledTask'   { Restore-TaskState     -Target $Target -Snapshot $Snapshot }
        'OptionalFeature' { Restore-FeatureState  -Target $Target -Snapshot $Snapshot }
        'Appx'            { throw 'Appx rollback requires reinstall; not supported by engine.' }
        default           { throw "Unknown target type '$($Target.Type)'" }
    }
}

function Invoke-TargetApply {
    param($Target)
    switch ($Target.Type) {
        'Registry'        { Set-RegistryTarget   -Target $Target }
        'Service'         { Set-ServiceStartType -Target $Target }
        'ScheduledTask'   { Set-TaskState        -Target $Target }
        'OptionalFeature' { Set-FeatureState     -Target $Target }
        'Appx'            { Remove-AppxTarget    -Target $Target }
        default           { throw "Unknown target type '$($Target.Type)'" }
    }
}

function Test-SingleTarget {
    param($Target)
    switch ($Target.Type) {
        'Registry'        { return Test-RegistryTarget -Target $Target }
        'Service'         { return Test-ServiceTarget  -Target $Target }
        'ScheduledTask'   { return Test-TaskTarget     -Target $Target }
        'OptionalFeature' { return Test-FeatureTarget  -Target $Target }
        'Appx'            { return Test-AppxTarget     -Target $Target }
        default           { return $false }
    }
}

function Test-TweakTargets {
    param($Tweak)
    foreach ($tg in $Tweak.Targets) {
        if (-not (Test-SingleTarget -Target $tg)) { return $false }
    }
    return $true
}

function Test-SnapshotEquals {
    # Read-back check after Undo: does the live state match the captured snapshot?
    param($Target, $Expected, $Actual)
    $e = [bool](Get-TweakProperty $Expected 'Existed'); $a = [bool](Get-TweakProperty $Actual 'Existed')
    if ($e -ne $a) { return $false }
    if (-not $e) { return $true }
    switch ($Target.Type) {
        'Registry' {
            return ($Expected.Kind -eq $Actual.Kind -and (@($Expected.Value) -join "`n") -eq (@($Actual.Value) -join "`n"))
        }
        'Service' {
            return ((ConvertTo-ServiceStartType $Expected.StartMode) -eq (ConvertTo-ServiceStartType $Actual.StartMode) -and
                    [bool](Get-TweakProperty $Expected 'Delayed') -eq [bool](Get-TweakProperty $Actual 'Delayed'))
        }
        'ScheduledTask'   { return (($Expected.State -eq 'Disabled') -eq ($Actual.State -eq 'Disabled')) }
        'OptionalFeature' { return ((ConvertTo-FeatureBaseState $Expected.State) -eq (ConvertTo-FeatureBaseState $Actual.State)) }
        default           { return $false }
    }
}