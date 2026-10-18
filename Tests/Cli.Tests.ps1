# Integration tests: run WinForge.ps1 in a child Windows PowerShell 5.1 process, the same
# way WinForge.bat does. Only read-only commands, plus Deploy into TestDrive.
BeforeDiscovery {
    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinForge.ps1'
    $state = Join-Path $TestDrive 'state'
    function Invoke-WfCli {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script @args -StateRoot $state 2>&1 | Out-String
        [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
    }
}

Describe 'Static checks' {
    It 'every script parses without errors' {
        $root = Split-Path -Parent $PSScriptRoot
        foreach ($f in Get-ChildItem $root -Recurse -Include *.ps1, *.psd1 | Where-Object FullName -notmatch '\\(dist|state)\\') {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because $f.FullName
        }
    }
}

Describe 'CLI (child process)' {
    It 'validates the catalog' {
        $r = Invoke-WfCli ValidateCatalog
        $r.Exit | Should -Be 0
        $r.Out | Should -Match 'Catalog OK'
    }
    It 'previews the Aggressive profile without crashing' {
        $r = Invoke-WfCli Preview -Profile Aggressive
        $r.Exit | Should -Be 0
        $r.Out | Should -Match '->'
    }
    It 'accepts comma-separated tweak IDs through -File' {
        $r = Invoke-WfCli Preview -Tweak 'taskbar-align-left,explorer-show-file-extensions'
        $r.Exit | Should -Be 0
        $r.Out | Should -Match 'explorer-show-file-extensions'
    }
    It 'lists, shows status and history' {
        (Invoke-WfCli List).Exit | Should -Be 0
        (Invoke-WfCli Status -Tweak taskbar-align-left).Exit | Should -Be 0
        (Invoke-WfCli History).Exit | Should -Be 0
        (Invoke-WfCli Privacy).Exit | Should -Be 0
    }
    It 'refuses Apply when not elevated' -Skip:$isElevated {
        $r = Invoke-WfCli Apply -Tweak taskbar-align-left -Force
        $r.Exit | Should -Not -Be 0
        $r.Out | Should -Match 'Administrator'
    }
    It 'rejects an invalid run ID' {
        (Invoke-WfCli Undo -RunId '..\x' -Force).Exit | Should -Not -Be 0
    }
    It 'writes a parseable answer file' {
        $f = Join-Path $TestDrive 'autounattend.xml'
        (Invoke-WfCli Deploy -OutFile $f).Exit | Should -Be 0
        { [xml](Get-Content $f -Raw) } | Should -Not -Throw
    }
    It 'installs nothing without -Force' {
        $r = Invoke-WfCli Install -Bundle Essentials
        $r.Out | Should -Match 'Dry run'
        $r.Out | Should -Not -Match 'InstalledVerified'
    }
}
