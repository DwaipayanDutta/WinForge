BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WinForgeLog -Context ([pscustomobject]@{ LogDir = $TestDrive; StateWritable = $false })
}

Describe 'Plan text (regression: preview crashed on non-registry targets under strict mode)' {
    It 'formats <Type> targets without throwing' -ForEach @(
        @{ Type = 'ScheduledTask'; Target = @{ Type = 'ScheduledTask'; Path = '\X\'; Name = 'T'; Value = 'Disabled' }; Snap = @{ Existed = $true; State = 'Ready' }; Expect = 'Task Ready -> Task Disabled' }
        @{ Type = 'Service'; Target = @{ Type = 'Service'; Name = 'S'; Value = 'Disabled' }; Snap = @{ Existed = $true; StartMode = 'Automatic'; Delayed = $true }; Expect = 'StartType Automatic \(delayed\) -> StartType Disabled' }
        @{ Type = 'OptionalFeature'; Target = @{ Type = 'OptionalFeature'; Name = 'F'; Value = 'Disabled' }; Snap = @{ Existed = $null; State = 'requires elevation to read' }; Expect = 'Unknown \(requires elevation to read\) -> Feature Disabled' }
        @{ Type = 'Appx'; Target = @{ Type = 'Appx'; Name = 'Microsoft.BingNews' }; Snap = @{ Existed = $true }; Expect = 'Installed -> Removed' }
        @{ Type = 'Registry'; Target = @{ Type = 'Registry'; Hive = 'HKCU'; Path = 'P'; Name = 'N'; Kind = 'DWord'; Value = 0 }; Snap = @{ Existed = $false; KeyExisted = $false }; Expect = '\(not present\) -> DWord 0' }
    ) {
        Set-StrictMode -Version Latest
        $plan = @([pscustomobject]@{ Id = 't'; Risk = 'Safe'; Supported = $true; Notes = $null; Before = @([pscustomobject]$Snap); After = @([pscustomobject]$Target) })
        (Get-OperationPlanText -Plan $plan) | Should -Match $Expect
        { Format-OperationPlan -Plan $plan } | Should -Not -Throw
    }
    It 'flags Danger tweaks and shows catalog notes' {
        $plan = @([pscustomobject]@{ Id = 'd'; Risk = 'Danger'; Supported = $true; Notes = 'Pro treats 0 as 1.'
            Before = @([pscustomobject]@{ Existed = $false; KeyExisted = $true }); After = @([pscustomobject]@{ Type = 'Registry'; Kind = 'DWord'; Value = 1 }) })
        $text = (Get-OperationPlanText -Plan $plan) -join "`n"
        $text | Should -Match 'DANGER: requires -Expert -TypedConfirmation d'
        $text | Should -Match 'NOTE: Pro treats 0 as 1.'
    }
}

Describe 'Plan compatibility' {
    It 'marks a tweak unsupported when its service does not exist' {
        Mock Get-TargetSnapshot { [pscustomobject]@{ Existed = $false; StartMode = $null; Delayed = $false } }
        $t = [pscustomobject]@{ Id = 's'; Name = 's'; Risk = 'Caution'; Targets = @([pscustomobject]@{ Type = 'Service'; Name = 'NoSuchSvc'; Value = 'Disabled' }) }
        $p = New-OperationPlan -Tweaks @($t) -SystemInfo (Get-WfTestSystem)
        $p[0].Supported | Should -BeFalse
        $p[0].Reason | Should -Match 'not present'
    }
    It 'keeps a registry tweak supported when the value is absent' {
        Mock Get-TargetSnapshot { [pscustomobject]@{ Existed = $false; KeyExisted = $false; Kind = $null; Value = $null } }
        $t = [pscustomobject]@{ Id = 'r'; Name = 'r'; Risk = 'Safe'; Targets = @([pscustomobject]@{ Type = 'Registry'; Hive = 'HKCU'; Path = 'P'; Name = 'N'; Kind = 'DWord'; Value = 0 }) }
        (New-OperationPlan -Tweaks @($t) -SystemInfo (Get-WfTestSystem))[0].Supported | Should -BeTrue
    }
}
