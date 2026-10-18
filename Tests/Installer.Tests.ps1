BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $ctx = New-WfTestContext
}

AfterAll { Remove-Variable -Name WfWingetArgs -Scope Global -ErrorAction SilentlyContinue }

Describe 'Installer' {
    It 'returns AlreadyInstalled without invoking the provider' {
        Mock Test-WinForgeAppInstalled { $true }
        Mock winget {}
        $app = [pscustomobject]@{ Id = '7zip'; Providers = [pscustomobject]@{ winget = '7zip.7zip'; choco = '7zip' } }
        (Install-WinForgeApp -App $app -Provider 'winget').Status | Should -Be 'AlreadyInstalled'
        Should -Invoke winget -Times 0
    }
    It 'reports Failed on a non-zero exit code' {
        Mock Test-WinForgeAppInstalled { $false }
        Mock winget { $global:LASTEXITCODE = 1 }
        $app = [pscustomobject]@{ Id = 'x'; Name = 'X'; Providers = [pscustomobject]@{ winget = 'x.y'; choco = $null } }
        (Install-WinForgeApp -App $app -Provider 'winget').Status | Should -Be 'Failed'
    }
    It 'pins winget to its own source and an exact ID' {
        Mock Test-WinForgeAppInstalled { $false }
        Mock winget { $global:WfWingetArgs = $args; $global:LASTEXITCODE = 0 }
        $app = [pscustomobject]@{ Id = '7zip'; Name = '7-Zip'; Providers = [pscustomobject]@{ winget = '7zip.7zip'; choco = '7zip' } }
        Install-WinForgeApp -App $app -Provider 'winget' | Out-Null
        ($global:WfWingetArgs -join ' ') | Should -Match '--id 7zip\.7zip --exact --source winget'
    }
    It 'does not install anything in a dry run' {
        Mock Test-WinForgeAppInstalled { $false }
        Mock winget {}
        $app = [pscustomobject]@{ Id = '7zip'; Name = '7-Zip'; Providers = [pscustomobject]@{ winget = '7zip.7zip'; choco = '7zip' } }
        (Install-WinForgeApp -App $app -Provider 'winget' -DryRun).Status | Should -Be 'WouldInstall'
        Should -Invoke winget -Times 0
    }
    It 'falls back to Chocolatey when winget reports failure and fallback is allowed' {
        Mock Get-WinForgeProviders { [pscustomobject]@{ winget = 'v1.9'; choco = '2.3.0' } }
        Mock Install-WinForgeApp { [pscustomobject]@{ Id = $App.Id; Status = $(if ($Provider -eq 'winget') { 'Failed' } else { 'InstalledVerified' }); Provider = $Provider; Reason = '' } }
        $r = Install-WinForgeBundle -Context $ctx -BundleId 'Gaming' -AllowChocoFallback
        @($r | Where-Object { $_.Provider -ne 'choco' -or $_.Status -ne 'InstalledVerified' }) | Should -BeNullOrEmpty
    }
    It 'creates a restore point before a real install and records the run' {
        $ictx = New-WfTestContext -Elevated
        Mock Get-WinForgeProviders { [pscustomobject]@{ winget = 'v1.9'; choco = $null } }
        Mock Install-WinForgeApp { [pscustomobject]@{ Id = $App.Id; Status = 'InstalledVerified'; Provider = $Provider; Reason = '' } }
        Mock Checkpoint-Computer {}
        Install-WinForgeBundle -Context $ictx -BundleId 'Gaming' | Out-Null
        Should -Invoke Checkpoint-Computer -Times 1
        $h = Get-WinForgeInstallHistory -Context $ictx
        $h.Bundle | Should -Be 'Gaming'
        $h.RestorePoint | Should -Be 'Created'
        $h.Installed | Should -Be 3
    }
    It 'records a failed restore point instead of aborting' {
        $ictx = New-WfTestContext -Elevated
        Mock Get-WinForgeProviders { [pscustomobject]@{ winget = 'v1.9'; choco = $null } }
        Mock Install-WinForgeApp { [pscustomobject]@{ Id = $App.Id; Status = 'InstalledVerified'; Provider = $Provider; Reason = '' } }
        Mock Checkpoint-Computer { throw 'System Restore is turned off' }
        Install-WinForgeBundle -Context $ictx -BundleId 'Gaming' | Out-Null
        (Get-WinForgeInstallHistory -Context $ictx).RestorePoint | Should -Match 'Not created: System Restore is turned off'
    }
    It 'takes no restore point and writes no history in a dry run' {
        $ictx = New-WfTestContext -Elevated
        Mock Get-WinForgeProviders { [pscustomobject]@{ winget = 'v1.9'; choco = $null } }
        Mock Install-WinForgeApp { [pscustomobject]@{ Id = $App.Id; Status = 'WouldInstall'; Provider = $Provider; Reason = '' } }
        Mock Checkpoint-Computer {}
        Install-WinForgeBundle -Context $ictx -BundleId 'Gaming' -DryRun | Out-Null
        Should -Invoke Checkpoint-Computer -Times 0
        @(Get-WinForgeInstallHistory -Context $ictx) | Should -BeNullOrEmpty
    }
    It 'does not fall back unless asked' {
        Mock Get-WinForgeProviders { [pscustomobject]@{ winget = 'v1.9'; choco = '2.3.0' } }
        Mock Install-WinForgeApp { [pscustomobject]@{ Id = $App.Id; Status = 'Failed'; Provider = $Provider; Reason = '' } }
        $r = Install-WinForgeBundle -Context $ctx -BundleId 'Gaming'
        @($r | Where-Object Provider -eq 'choco') | Should -BeNullOrEmpty
    }
}
