# Integration tests: run WinForge.ps1 in a child Windows PowerShell 5.1 process, the same
# way WinForge.bat does. Only read-only commands, plus Deploy into TestDrive.
BeforeDiscovery {
    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinForge.ps1'
    $state = Join-Path $TestDrive 'state'
    function Invoke-WfCli {
        # The child's stderr is expected output here; with a caller's 'Stop' preference
        # (as in packaging/check.ps1) Windows PowerShell would turn it into an exception.
        $ErrorActionPreference = 'Continue'
        $out =& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script @args -StateRoot $state 2>&1 | Out-String
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

Describe 'GUI robustness (static)' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'UI\MainForm.ps1'), [ref]$null, [ref]$null)
        $handlers = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -like 'Add_*' }, $true)
    }
    It 'wraps every click, tick and selection handler in Invoke-WinForgeUiAction' {
        $handlers.Count | Should -BeGreaterThan 5
        foreach ($h in $handlers | Where-Object { $_.Member.Value -in 'Add_Click','Add_Tick','Add_SelectedIndexChanged' }) {
            $h.Arguments[0].Extent.Text | Should -Match '^\{\s*Invoke-WinForgeUiAction' -Because $h.Extent.Text.Substring(0, [Math]::Min(80, $h.Extent.Text.Length))
        }
    }
    It 'handlers reach controls only through $script:wfUi, not function locals' {
        $locals = 'progress','applyBtn','cancelBtn','expertChk','list','grid','details','catalog','sys'
        foreach ($h in $handlers) {
            $vars = $h.Arguments[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath }
            @($vars | Where-Object { $locals -contains $_ }) | Should -BeNullOrEmpty -Because $h.Member.Value
        }
    }
    It 'has a Cancel button wired to the run' {
        (Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'UI\MainForm.ps1') -Raw) | Should -Match 'Runner\.Sync\.Cancelled = \$true'
    }
}

Describe 'Launcher' {
    BeforeAll { $bat = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinForge.bat' }
    It 'uses CRLF line endings (cmd.exe misparses LF batch files)' {
        $raw = [IO.File]::ReadAllText($bat)
        [regex]::Matches($raw, "(?<!`r)`n").Count | Should -Be 0
    }
    It 'opens the GUI when started without arguments (double-click)' {
        (Get-Content $bat -Raw) | Should -Match 'WF_PS1%" Gui'
    }
    It 'keeps the elevated window open for CLI commands' {
        (Get-Content $bat -Raw) | Should -Match "-NoExit -File "
    }
    It 'checks elevation with fltmc, not net session (no relaunch loop when the Server service is off)' {
        $code = (Get-Content $bat) | Where-Object { $_ -notmatch '^\s*rem ' }
        ($code -join "`n") | Should -Match '(?m)^fltmc >nul' -Because 'fltmc works without LanmanServer'
        ($code -join "`n") | Should -Not -Match 'net session'
    }
    It 'elevates powershell.exe -File directly, never cmd.exe or the .bat itself' {
        $code = ((Get-Content $bat) | Where-Object { $_ -notmatch '^\s*rem ' }) -join "`n"
        $code | Should -Not -Match 'cmd\.exe|/k |WF_SELF'
        $code | Should -Match "Start-Process -FilePath powershell\.exe -ArgumentList \`$argList -Verb RunAs"
    }
    It 'shows the script help, not just the syntax line' {
        (Get-Help (Join-Path (Split-Path -Parent $PSScriptRoot) 'WinForge.ps1')).Synopsis | Should -Match 'preview-first'
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
