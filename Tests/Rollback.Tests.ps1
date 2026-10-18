BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # Every registry provider call below is mocked. The original version of this file
    # called the real New-Item and left HKCU:\Software\WinForgeTest behind on the host.
    $target = [pscustomobject]@{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\WinForgeTest'; Name = 'X'; Kind = 'DWord'; Value = 1 }
}

Describe 'Registry capture' {
    It 'captures REG_EXPAND_SZ unexpanded' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [pscustomobject]@{ X = 'ignored' } }
        Mock Get-Item {
            $o = [pscustomobject]@{}
            $o | Add-Member ScriptMethod GetValueKind { param($n) [Microsoft.Win32.RegistryValueKind]::ExpandString }
            $o | Add-Member ScriptMethod GetValue { param($n, $d, $opt)
                if ($opt -eq [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) { '%USERPROFILE%\x' } else { 'C:\Users\me\x' } }
            $o
        }
        $s = Get-RegistryState -Target $target
        $s.Kind | Should -Be 'ExpandString'
        $s.Value | Should -Be '%USERPROFILE%\x'
    }
    It 'records whether the key existed' {
        Mock Test-Path { $false }
        (Get-RegistryState -Target $target).KeyExisted | Should -BeFalse
    }
}

Describe 'Registry rollback' {
    BeforeEach {
        Mock Test-Path { $true }
        Mock New-Item {}
        Mock New-ItemProperty {}
        Mock Remove-ItemProperty {}
        Mock Remove-Item {}
    }
    It 'removes a value that did not exist before' {
        Mock Get-Item { [pscustomobject]@{ ValueCount = 1; SubKeyCount = 0 } }
        Restore-RegistryState -Target $target -Snapshot ([pscustomobject]@{ Existed = $false; KeyExisted = $true; Kind = $null; Value = $null })
        Should -Invoke Remove-ItemProperty -Times 1 -Exactly
        Should -Invoke Remove-Item -Times 0
    }
    It 'removes the key too when WinForge created it and it is now empty' {
        Mock Get-Item { [pscustomobject]@{ ValueCount = 0; SubKeyCount = 0 } }
        Restore-RegistryState -Target $target -Snapshot ([pscustomobject]@{ Existed = $false; KeyExisted = $false; Kind = $null; Value = $null })
        Should -Invoke Remove-Item -Times 1 -Exactly
    }
    It 'keeps a created key that now holds other values' {
        Mock Get-Item { [pscustomobject]@{ ValueCount = 2; SubKeyCount = 0 } }
        Restore-RegistryState -Target $target -Snapshot ([pscustomobject]@{ Existed = $false; KeyExisted = $false; Kind = $null; Value = $null })
        Should -Invoke Remove-Item -Times 0
    }
    It 'restores an existing value with its original kind and .NET type after a JSON round trip' {
        $snap = ([pscustomobject]@{ Existed = $true; KeyExisted = $true; Kind = 'DWord'; Value = 42 } | ConvertTo-Json | ConvertFrom-Json)
        Restore-RegistryState -Target $target -Snapshot $snap
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter { $Value -is [int] -and $Value -eq 42 -and $PropertyType -eq 'DWord' }
    }
    It 'restores Binary data as bytes' {
        $snap = ([pscustomobject]@{ Existed = $true; KeyExisted = $true; Kind = 'Binary'; Value = @(1, 2, 255) } | ConvertTo-Json | ConvertFrom-Json)
        Restore-RegistryState -Target $target -Snapshot $snap
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter { $Value -is [byte[]] -and $Value[2] -eq 255 -and $PropertyType -eq 'Binary' }
    }
}

Describe 'Registry value conversion' {
    It 'keeps a one-item MultiString as a string array' {
        $v = ConvertTo-RegistryValue @('only') 'MultiString'
        , $v | Should -BeOfType [string[]]
        $v.Count | Should -Be 1
    }
}

Describe 'Registry verification' {
    It 'treats a value of the wrong kind as not applied' {
        Mock Get-RegistryState { [pscustomobject]@{ Existed = $true; KeyExisted = $true; Kind = 'String'; Value = '1' } }
        Test-RegistryTarget -Target $target | Should -BeFalse
    }
}

Describe 'Service adapter' {
    It 'normalises Auto to Automatic and records delayed start' {
        Mock Get-CimInstance { [pscustomobject]@{ StartMode = 'Auto'; DelayedAutoStart = $true } }
        $s = Get-ServiceState -Target ([pscustomobject]@{ Name = 'DiagTrack' })
        $s.StartMode | Should -Be 'Automatic'
        $s.Delayed | Should -BeTrue
    }
    It 'verifies an Automatic target against an Auto service' {
        Mock Get-CimInstance { [pscustomobject]@{ StartMode = 'Auto'; DelayedAutoStart = $false } }
        Test-ServiceTarget -Target ([pscustomobject]@{ Name = 'X'; Value = 'Automatic' }) | Should -BeTrue
    }
    It 'restores delayed automatic start with sc.exe, not Set-Service' {
        Mock Invoke-ScConfig {}
        Mock Set-Service {}
        Restore-ServiceState -Target ([pscustomobject]@{ Name = 'DiagTrack' }) -Snapshot ([pscustomobject]@{ Existed = $true; StartMode = 'Auto'; Delayed = $true })
        Should -Invoke Invoke-ScConfig -Times 1 -ParameterFilter { $Start -eq 'delayed-auto' }
        Should -Invoke Set-Service -Times 0
    }
    It 'restores a record from the old format (StartMode Auto) as Automatic' {
        Mock Set-Service {}
        Restore-ServiceState -Target ([pscustomobject]@{ Name = 'DiagTrack' }) -Snapshot ([pscustomobject]@{ Existed = $true; StartMode = 'Auto' })
        Should -Invoke Set-Service -Times 1 -ParameterFilter { $StartupType -eq 'Automatic' }
    }
    It 'rejects a service name that would inject into the WQL filter' {
        { Get-ServiceState -Target ([pscustomobject]@{ Name = "x' OR Name='y" }) } | Should -Throw '*Invalid service name*'
    }
}

Describe 'Optional feature adapter' {
    It 'treats <State> as <Base>' -ForEach @(
        @{ State = 'DisablePending'; Base = 'Disabled' }, @{ State = 'DisabledWithPayloadRemoved'; Base = 'Disabled' }
        @{ State = 'EnablePending'; Base = 'Enabled' }, @{ State = 'Enabled'; Base = 'Enabled' }
    ) { ConvertTo-FeatureBaseState $State | Should -Be $Base }
    It 'verifies a disable that is pending restart' {
        Mock Get-FeatureState { [pscustomobject]@{ Existed = $true; State = 'DisablePending' } }
        Test-FeatureTarget -Target ([pscustomobject]@{ Name = 'TelnetClient'; Value = 'Disabled' }) | Should -BeTrue
    }
    It 'restores an EnablePending snapshot by enabling' {
        Mock Enable-WindowsOptionalFeature {}
        Mock Disable-WindowsOptionalFeature {}
        Restore-FeatureState -Target ([pscustomobject]@{ Name = 'TelnetClient' }) -Snapshot ([pscustomobject]@{ Existed = $true; State = 'EnablePending' })
        Should -Invoke Enable-WindowsOptionalFeature -Times 1
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
    }
}

Describe 'Host safety' {
    It 'left no test key in the real registry' {
        Test-Path 'HKCU:\Software\WinForgeTest' | Should -BeFalse
    }
}
