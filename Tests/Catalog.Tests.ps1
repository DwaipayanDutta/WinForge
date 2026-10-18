BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $ctx = New-WfTestContext

    function Test-WfOne {
        param($Tweak, [object[]] $Profiles = @(), [object[]] $Apps)
        $dir = New-WfTestCatalog -Tweaks @($Tweak) -Profiles $Profiles -Apps $Apps
        Set-StrictMode -Version Latest
        return Test-WinForgeCatalog -Context ([pscustomobject]@{ CatalogRoot = $dir })
    }
}

Describe 'Catalog validation' {
    It 'accepts the shipped catalog' {
        Set-StrictMode -Version Latest
        $r = Test-WinForgeCatalog -Context $ctx
        $r.Errors | Should -BeNullOrEmpty
        $r.Valid | Should -BeTrue
    }
    It 'accepts the minimal test tweak' {
        (Test-WfOne (New-WfTestTweak)).Valid | Should -BeTrue
    }
    It 'reports the malformed fixture instead of crashing under strict mode' {
        $dir = Join-Path $TestDrive 'fixture'; New-Item -ItemType Directory $dir | Out-Null
        Copy-Item (Join-Path $PSScriptRoot 'Fixtures\bad-tweaks.json') (Join-Path $dir 'tweaks.json')
        Set-StrictMode -Version Latest
        $r = Test-WinForgeCatalog -Context ([pscustomobject]@{ CatalogRoot = $dir })
        $r.Valid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'forbidden'
        ($r.Errors -join ' ') | Should -Match 'invalid Id'
    }
    It 'reports invalid JSON' {
        $dir = Join-Path $TestDrive 'badjson'; New-Item -ItemType Directory $dir | Out-Null
        '{ "tweaks": [ ' | Set-Content (Join-Path $dir 'tweaks.json')
        (Test-WinForgeCatalog -Context ([pscustomobject]@{ CatalogRoot = $dir })).Valid | Should -BeFalse
    }
    It 'rejects a free-form <Field> field' -ForEach @(@{ Field = 'Script' }, @{ Field = 'Command' }, @{ Field = 'ScriptBlock' }) {
        $t = New-WfTestTweak; $t[$Field] = 'calc.exe'
        $r = Test-WfOne $t
        $r.Valid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'forbidden'
    }
    It 'rejects unknown top-level and target fields' {
        $t = New-WfTestTweak; $t.Payload = 'x'
        $t.Targets[0].OnApply = 'x'
        $e = (Test-WfOne $t).Errors -join ' '
        $e | Should -Match "unknown field 'Payload'"
        $e | Should -Match "unknown field 'OnApply'"
    }
    It 'rejects a Danger tweak in a profile' {
        $r = Test-WfOne (New-WfTestTweak -Risk 'Danger') -Profiles @(@{ Id = 'P'; Name = 'P'; TweakIds = @('test-tweak') })
        $r.Valid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'Danger'
    }
    It 'rejects a profile referencing an unknown tweak' {
        ((Test-WfOne (New-WfTestTweak) -Profiles @(@{ Id = 'P'; Name = 'P'; TweakIds = @('nope') })).Errors -join ' ') | Should -Match 'unknown tweak'
    }
    It 'rejects registry targets that launch code: <Path>\<Name>' -ForEach @(
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe'; Name = 'Debugger' }
        @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'Evil' }
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Name = 'Evil' }
        @{ Hive = 'HKLM'; Path = 'SYSTEM\CurrentControlSet\Services\Spooler'; Name = 'ImagePath' }
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; Name = 'Userinit' }
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableLUA' }
        @{ Hive = 'HKCU'; Path = 'Software\Classes\CLSID\{00000000-0000-0000-0000-000000000000}\InprocServer32'; Name = 'x' }
        @{ Hive = 'HKCU'; Path = 'Software\Classes\exefile\shell\open\command'; Name = 'x' }
    ) {
        $t = New-WfTestTweak -Targets @(@{ Type = 'Registry'; Hive = $Hive; Path = $Path; Name = $Name; Kind = 'String'; Value = 'cmd.exe' })
        $r = Test-WfOne $t
        $r.Valid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'not allowed'
    }
    It 'still allows ordinary policy values under Services and Winlogon' {
        (Test-WfOne (New-WfTestTweak -Targets @(@{ Type = 'Registry'; Hive = 'HKLM'; Path = 'SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\StandardProfile'; Name = 'EnableFirewall'; Kind = 'DWord'; Value = 0 }))).Valid | Should -BeTrue
        (Test-WfOne (New-WfTestTweak -Targets @(@{ Type = 'Registry'; Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; Name = 'EnableFirstLogonAnimation'; Kind = 'DWord'; Value = 0 }))).Valid | Should -BeTrue
    }
    It 'rejects path traversal, wildcards and unknown hives' {
        foreach ($tg in @(
            @{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\..\..\SOFTWARE\X'; Name = 'A'; Kind = 'DWord'; Value = 1 }
            @{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\*'; Name = 'A'; Kind = 'DWord'; Value = 1 }
            @{ Type = 'Registry'; Hive = 'HKU'; Path = 'Software\X'; Name = 'A'; Kind = 'DWord'; Value = 1 }
            @{ Type = 'Registry'; Hive = 'HKCU'; Path = 'HKLM:\SOFTWARE\X'; Name = 'A'; Kind = 'DWord'; Value = 1 }
        )) { (Test-WfOne (New-WfTestTweak -Targets @($tg))).Valid | Should -BeFalse }
    }
    It 'rejects a wildcard Appx name (would remove every package)' {
        $t = New-WfTestTweak -Targets @(@{ Type = 'Appx'; Name = '*' })
        $t.Reversible = 'partial'; $t.Undo = @{ Strategy = 'ReinstallAppx' }; $t.Verification = @{ Type = 'AppxAbsent' }
        ((Test-WfOne $t).Errors -join ' ') | Should -Match 'invalid Appx Name'
    }
    It 'rejects Appx removal labelled fully reversible' {
        $t = New-WfTestTweak -Targets @(@{ Type = 'Appx'; Name = 'Microsoft.BingNews' })
        $t.Verification = @{ Type = 'AppxAbsent' }
        $e = (Test-WfOne $t).Errors -join ' '
        $e | Should -Match 'RestoreCapturedState'
        $e | Should -Match 'fully reversible'
    }
    It 'rejects mistyped values and invalid service, task and feature targets' {
        (Test-WfOne (New-WfTestTweak -Targets @(@{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\X'; Name = 'A'; Kind = 'DWord'; Value = 'one' }))).Valid | Should -BeFalse
        (Test-WfOne (New-WfTestTweak -Targets @(@{ Type = 'Service'; Name = "x' OR Name='y"; Value = 'Disabled' }))).Valid | Should -BeFalse
        (Test-WfOne (New-WfTestTweak -Targets @(@{ Type = 'Service'; Name = 'DiagTrack'; Value = 'Auto' }))).Valid | Should -BeFalse
        (Test-WfOne (New-WfTestTweak -Targets @(@{ Type = 'ScheduledTask'; Path = 'Microsoft\'; Name = 'T'; Value = 'Disabled' }))).Valid | Should -BeFalse
        (Test-WfOne (New-WfTestTweak -Targets @(@{ Type = 'OptionalFeature'; Name = 'A B'; Value = 'Disabled' }))).Valid | Should -BeFalse
    }
    It 'rejects package IDs that could be parsed as provider options' {
        $apps = @(@{ Id = 'evil'; Name = 'Evil'; Category = 'Utility'; Providers = @{ winget = '--source=http://evil'; choco = 'x y' } })
        $e = (Test-WfOne (New-WfTestTweak) -Apps $apps).Errors -join ' '
        $e | Should -Match 'invalid winget package ID'
        $e | Should -Match 'invalid choco package ID'
    }
    It 'Assert-WinForgeCatalog throws on an invalid catalog' {
        $t = New-WfTestTweak; $t.Script = 'calc.exe'
        $dir = New-WfTestCatalog -Tweaks @($t)
        { Assert-WinForgeCatalog -Context ([pscustomobject]@{ CatalogRoot = $dir }) } | Should -Throw '*failed validation*'
    }
}
