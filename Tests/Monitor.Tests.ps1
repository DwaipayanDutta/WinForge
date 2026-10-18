BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Connection classification' {
    It 'classifies <HostName> as <Class>' -ForEach @(
        @{ HostName = 'v10.events.data.microsoft.com'; Class = 'Telemetry' }
        @{ HostName = 'x.smartscreen.microsoft.com'; Class = 'Security' }
        @{ HostName = 'a.b.windowsupdate.com'; Class = 'Update' }
        @{ HostName = 'www.bing.com.'; Class = 'General' }
        @{ HostName = 'example.org'; Class = 'Other' }
        @{ HostName = 'notmicrosoft.com'; Class = 'Other' }
        @{ HostName = ''; Class = 'Unresolved' }
    ) { Get-WinForgeConnectionClass -Hostname $HostName | Should -Be $Class }
}

Describe 'Connection snapshot' {
    BeforeEach {
        Mock Get-NetTCPConnection { @(
            [pscustomobject]@{ LocalAddress = '10.0.0.2'; LocalPort = 50000; RemoteAddress = '20.1.1.1'; RemotePort = 443; State = 'Established'; OwningProcess = $PID }
            [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 135; RemoteAddress = '0.0.0.0'; RemotePort = 0; State = 'Listen'; OwningProcess = $PID }
        ) }
        Mock Resolve-DnsName { [pscustomobject]@{ NameHost = 'v10.events.data.microsoft.com' } }
    }
    It 'does no DNS lookups unless asked' {
        $s = @(Get-WinForgeConnectionSnapshot)
        Should -Invoke Resolve-DnsName -Times 0
        ($s | Where-Object State -eq 'Established').Class | Should -Match 'ResolveNames'
        ($s | Where-Object State -eq 'Listen').Class | Should -Be 'Local'
    }
    It 'classifies established connections with -ResolveNames' {
        $s = @(Get-WinForgeConnectionSnapshot -ResolveNames -EstablishedOnly)
        $s.Count | Should -Be 1
        $s[0].Class | Should -Be 'Telemetry'
        $s[0].RemoteHost | Should -Be 'v10.events.data.microsoft.com'
    }
}

Describe 'Snapshot export and compare' {
    It 'exports, refuses to overwrite, and reports new, gone and remaining connections' {
        $ctx = New-WfTestContext
        Mock Get-WinForgeConnectionSnapshot { @(
            [pscustomobject]@{ Process = 'a'; RemoteAddress = '1.1.1.1'; RemotePort = 443; Class = 'Other' }
            [pscustomobject]@{ Process = 'b'; RemoteAddress = '2.2.2.2'; RemotePort = 443; Class = 'Telemetry' }
        ) }
        $before = Export-WinForgeConnectionSnapshot -Context $ctx -OutFile (Join-Path $TestDrive 'before.json')
        { Export-WinForgeConnectionSnapshot -Context $ctx -OutFile $before } | Should -Throw '*overwrite*'
        Mock Get-WinForgeConnectionSnapshot { @(
            [pscustomobject]@{ Process = 'a'; RemoteAddress = '1.1.1.1'; RemotePort = 443; Class = 'Other' }
            [pscustomobject]@{ Process = 'c'; RemoteAddress = '3.3.3.3'; RemotePort = 80; Class = 'Other' }
        ) }
        $after = Export-WinForgeConnectionSnapshot -Context $ctx -OutFile (Join-Path $TestDrive 'after.json')
        $diff = Compare-WinForgeConnectionSnapshots -Before $before -After $after
        ($diff | Where-Object Change -eq 'Gone').Connection | Should -Be 'b -> 2.2.2.2:443'
        ($diff | Where-Object Change -eq 'New').Connection | Should -Be 'c -> 3.3.3.3:80'
        ($diff | Where-Object Change -eq 'Remains').Connection | Should -Be 'a -> 1.1.1.1:443'
    }
}

Describe 'Security audit' {
    It 'reports a missing registry value as null, not an error' {
        Get-WinForgeRegistryValueOrNull 'HKLM:\SOFTWARE\WinForgeDoesNotExist' 'X' | Should -BeNullOrEmpty
    }
    It 'labels SmartScreen values by source' {
        $p = Get-WinForgeSecurityPosture
        $p.SmartScreenPolicy | Should -Match 'policy'
        $p.SmartScreenSetting | Should -Match 'configured|Not configured'
    }
}
