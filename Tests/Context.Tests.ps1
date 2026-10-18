BeforeDiscovery {
    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'State folder protection' {
    It 'grants write access only to SYSTEM and Administrators' {
        $acl = New-WinForgeStateAcl
        $acl.AreAccessRulesProtected | Should -BeTrue
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $rules.Count | Should -Be 3
        $writers = $rules | Where-Object { ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData) -ne 0 } | ForEach-Object { $_.IdentityReference.Value }
        @($writers | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        ($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' }).FileSystemRights.ToString() | Should -Match 'ReadAndExecute'
    }
    It 'resets children to inherit from the protected root' {
        $dir = Join-Path $TestDrive 'acl'; New-Item -ItemType Directory "$dir\runs" -Force | Out-Null
        'x' | Set-Content "$dir\runs\r.json"
        Mock Set-Acl {}
        Protect-WinForgeStateRoot -Path $dir
        Should -Invoke Set-Acl -Times 1 -ParameterFilter { $LiteralPath -eq $dir -and $AclObject.AreAccessRulesProtected }
        Should -Invoke Set-Acl -Times 2 -ParameterFilter { $LiteralPath -ne $dir -and -not $AclObject.AreAccessRulesProtected }
    }
}

Describe 'Default state root' {
    It 'is not created by a non-elevated process' -Skip:$isElevated {
        $saved = $env:ProgramData
        try {
            $env:ProgramData = Join-Path $TestDrive 'pd'
            $ctx = New-WinForgeContext
            $ctx.StateRoot | Should -Be (Join-Path $env:ProgramData 'WinForge')
            $ctx.StateWritable | Should -BeFalse
            Test-Path $ctx.StateRoot | Should -BeFalse
        } finally { $env:ProgramData = $saved }
    }
    It 'uses an explicit -StateRoot as given' {
        $ctx = New-WinForgeContext -StateRoot (Join-Path $TestDrive 'explicit')
        Test-Path $ctx.RunDir | Should -BeTrue
        $ctx.StateWritable | Should -BeTrue
    }
}
