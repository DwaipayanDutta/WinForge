BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $sys = [pscustomobject]@{ Build = 19045; Edition = 'Home'; Arch = 'x64'; Managed = $false; Elevated = $true }
}

Describe 'Compatibility gate' {
    It 'skips a tweak below MinBuild' {
        $t = [pscustomobject]@{ MinBuild = 22000; MaxBuild = $null; Editions = $null; Architecture = $null; Risk = 'Safe' }
        (Test-TweakCompatibility -Tweak $t -SystemInfo $sys).Supported | Should -BeFalse
    }
    It 'skips a tweak above MaxBuild' {
        $t = [pscustomobject]@{ MinBuild = 10240; MaxBuild = 19000; Risk = 'Safe' }
        (Test-TweakCompatibility -Tweak $t -SystemInfo $sys).Supported | Should -BeFalse
    }
    It 'skips an edition not in the list' {
        $t = [pscustomobject]@{ MinBuild = 10240; MaxBuild = $null; Editions = @('Pro'); Architecture = $null; Risk = 'Safe' }
        (Test-TweakCompatibility -Tweak $t -SystemInfo $sys).Supported | Should -BeFalse
    }
    It 'allows a Safe tweak on a managed device but skips Caution' {
        $managed = $sys.PSObject.Copy(); $managed.Managed = $true
        $safe = [pscustomobject]@{ MinBuild = 10240; MaxBuild = $null; Editions = $null; Architecture = $null; Risk = 'Safe' }
        (Test-TweakCompatibility -Tweak $safe -SystemInfo $managed).Supported | Should -BeTrue
        $caution = $safe.PSObject.Copy(); $caution.Risk = 'Caution'
        (Test-TweakCompatibility -Tweak $caution -SystemInfo $managed).Supported | Should -BeFalse
    }
    It 'tolerates tweaks without optional fields under strict mode' {
        Set-StrictMode -Version Latest
        (Test-TweakCompatibility -Tweak ([pscustomobject]@{ Risk = 'Safe' }) -SystemInfo $sys).Supported | Should -BeTrue
    }
}

Describe 'Edition mapping (regression: Pro machines skipped every edition-scoped tweak)' {
    It 'maps <Id> to <Family>' -ForEach @(
        @{ Id = 'Core'; Family = 'Home' }, @{ Id = 'CoreSingleLanguage'; Family = 'Home' }
        @{ Id = 'Professional'; Family = 'Pro' }, @{ Id = 'ProfessionalWorkstation'; Family = 'Pro' }
        @{ Id = 'Enterprise'; Family = 'Enterprise' }, @{ Id = 'EnterpriseS'; Family = 'Enterprise' }
        @{ Id = 'IoTEnterprise'; Family = 'Enterprise' }, @{ Id = 'Education'; Family = 'Education' }
        @{ Id = 'ServerStandard'; Family = 'Server' }, @{ Id = 'Something'; Family = 'Unknown' }
    ) {
        ConvertTo-WinForgeEditionFamily $Id | Should -Be $Family
    }
    It 'supports the Pro-scoped telemetry tweak on an EditionID of Professional' {
        Mock Get-ItemProperty { [pscustomobject]@{ EditionID = 'Professional' } } -ParameterFilter { $Path -like '*Windows NT\CurrentVersion' }
        $info = Get-WinForgeSystemInfo
        $info.Edition | Should -Be 'Pro'
        $info.EditionId | Should -Be 'Professional'
        $t = [pscustomobject]@{ Editions = @('Pro','Enterprise','Education'); Risk = 'Safe' }
        $info.Managed = $false
        (Test-TweakCompatibility -Tweak $t -SystemInfo $info).Supported | Should -BeTrue
    }
}

Describe 'Telemetry honesty' {
    It 'says Pro cannot turn diagnostic data fully off' {
        Mock Get-WinForgeSystemInfo { Get-WfTestSystem -Edition 'Pro' }
        (Get-WinForgeTelemetryHonesty).PolicyNote | Should -Match 'Required \(1\) on Pro'
    }
    It 'says Home cannot turn diagnostic data fully off' {
        Mock Get-WinForgeSystemInfo { Get-WfTestSystem -Edition 'Home' }
        (Get-WinForgeTelemetryHonesty).PolicyNote | Should -Match 'Required \(1\) on Home'
    }
}
