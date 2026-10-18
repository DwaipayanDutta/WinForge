Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

function Get-WinForgeDashboardText {
    param($Context)
    $sys = Get-WinForgeSystemInfo
    $providers = @()
    if (Get-Command winget -ErrorAction SilentlyContinue) { $providers += 'winget' }
    if (Get-Command choco  -ErrorAction SilentlyContinue) { $providers += 'choco' }
    $last = Get-WinForgeHistory -Context $Context | Select-Object -First 1
    $posture = Get-WinForgeSecurityPosture
    $lines = @(
        "Build:      $($sys.Build)"
        "Edition:    $($sys.Edition)"
        "Arch:       $($sys.Arch)"
        "Managed:    $($sys.Managed)"
        "Elevated:   $($sys.Elevated)"
        "Providers:  $($providers -join ', ')"
        "State root: $($Context.StateRoot)"
        "Last run:   $(if ($last) { $last.RunId } else { 'none' })"
        ''
        'Security posture:'
    )
    $posture.PSObject.Properties | ForEach-Object { $lines += "  $($_.Name): $($_.Value)" }
    return ($lines -join "`r`n")
}

function Invoke-WinForgeUiAction {
    # Every event handler body runs through here. An exception inside a WinForms event
    # handler otherwise escapes into the message loop and can close the window without a
    # message; here it is logged and shown instead.
    param([string] $Title, [scriptblock] $Action)
    try { & $Action }
    catch {
        Write-WinForgeLog -Level Error -Message "GUI ${Title}: $($_.Exception.Message)"
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "$Title failed", 'OK', 'Error')
    }
}

function Get-WinForgeCheckedTweakIds {
    $ui = $script:wfUi
    $ids = @(); foreach ($i in $ui.List.CheckedIndices) { $ids += $ui.Map[[int]$i] }
    return $ids
}

function Update-WinForgeHistoryGrid {
    $dt = New-Object System.Data.DataTable
    foreach ($c in 'RunId','StartedUtc','State','Applied','Failed','Restored') { [void]$dt.Columns.Add($c) }
    foreach ($h in (Get-WinForgeHistory -Context $script:wfUi.Context)) { [void]$dt.Rows.Add($h.RunId, $h.StartedUtc, $h.State, $h.Applied, $h.Failed, $h.Restored) }
    $script:wfUi.Grid.DataSource = $dt
}

function Complete-WinForgeApply {
    # Called from the timer tick on the UI thread once the background run reports Done.
    $ui = $script:wfUi
    $s = $ui.Runner.Sync
    $ui.Timer.Stop()
    try { $ui.Runner.PS.EndInvoke($ui.Runner.Handle) | Out-Null } catch { Write-WinForgeLog -Level Error -Message "GUI apply: $($_.Exception.Message)" }
    $ui.Runner.PS.Runspace.Close(); $ui.Runner.PS.Dispose()
    $ui.Progress.Value = 100
    $ui.Apply.Enabled = $true; $ui.Cancel.Enabled = $false
    Update-WinForgeHistoryGrid
    if ($s.Error) { [void][System.Windows.Forms.MessageBox]::Show($s.Error, 'Apply failed', 'OK', 'Error') }
    else {
        $title = if ($s.Cancelled) { 'Apply cancelled (completed tweaks are recorded and can be undone)' } else { 'Apply result' }
        [void][System.Windows.Forms.MessageBox]::Show(($s.Result | Format-Table Id, Status, Reason -AutoSize | Out-String), $title)
    }
}

function Show-WinForgeMainForm {
    param($Context)

    try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) }
    catch { Write-Verbose 'Unhandled-exception mode already set' }
    [System.Windows.Forms.Application]::add_ThreadException({
        $e = $args[1]
        Write-WinForgeLog -Level Error -Message "GUI unhandled: $($e.Exception.Message)"
        [void][System.Windows.Forms.MessageBox]::Show($e.Exception.Message, 'WinForge error', 'OK', 'Error')
    })

    # All state the event handlers need lives in this one script-scoped table. Handlers
    # run after Show-WinForgeMainForm's locals would normally be out of reach, so nothing
    # relies on PowerShell's dynamic scope lookup.
    $script:wfUi = @{ Context = $Context; Sys = (Get-WinForgeSystemInfo); Catalog = (Get-WinForgeCatalog -Context $Context); Map = @{} }
    $ui = $script:wfUi

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "WinForge $($Context.Version)"
    $form.Size = New-Object System.Drawing.Size(1100, 720)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $ui.Form = $form

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'

    $tweaksTab = New-Object System.Windows.Forms.TabPage
    $tweaksTab.Text = 'Tweaks'

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.SplitterDistance = 520

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Dock = 'Fill'; $list.CheckOnClick = $true
    foreach ($t in $ui.Catalog.tweaks) {
        $idx = $list.Items.Add(("[{0}] {1}  ({2})" -f $t.Risk, $t.Name, $t.Category))
        $ui.Map[$idx] = $t.Id
    }
    $split.Panel1.Controls.Add($list)
    $ui.List = $list

    $details = New-Object System.Windows.Forms.TextBox
    $details.Dock = 'Fill'; $details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
    $split.Panel2.Controls.Add($details)
    $ui.Details = $details

    $list.Add_SelectedIndexChanged({ Invoke-WinForgeUiAction 'Details' {
        $ui = $script:wfUi
        if ($ui.List.SelectedIndex -lt 0) { return }
        $id = $ui.Map[$ui.List.SelectedIndex]
        $t = $ui.Catalog.tweaks | Where-Object { $_.Id -eq $id }
        $plan = New-OperationPlan -Tweaks @($t) -SystemInfo $ui.Sys
        $ui.Details.Text = @(
            "Id:           $($t.Id)"
            "Risk:         $($t.Risk)"
            "Reversible:   $($t.Reversible)"
            "NeedsRestart: $($t.NeedsRestart)"
            "Status:       $(Get-WinForgeTweakStatusText -Tweak $t -SystemInfo $ui.Sys)"
            "Description:  $($t.Description)"
            "Source:       $(Get-TweakProperty $t 'SourceUrl')"
            ''
            'Current -> new:'
            ((Get-OperationPlanText -Plan $plan) -join "`r`n")
        ) -join "`r`n"
    } })

    $tweaksTab.Controls.Add($split)

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 80
    $previewBtn = New-Object System.Windows.Forms.Button
    $previewBtn.Text = 'Preview'; $previewBtn.Location = New-Object System.Drawing.Point(10, 10); $previewBtn.Width = 100
    $applyBtn = New-Object System.Windows.Forms.Button
    $applyBtn.Text = 'Apply'; $applyBtn.Location = New-Object System.Drawing.Point(120, 10); $applyBtn.Width = 100
    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = 'Cancel'; $cancelBtn.Location = New-Object System.Drawing.Point(230, 10); $cancelBtn.Width = 100; $cancelBtn.Enabled = $false
    $expertChk = New-Object System.Windows.Forms.CheckBox
    $expertChk.Text = 'Expert mode'; $expertChk.Location = New-Object System.Drawing.Point(350, 12); $expertChk.Width = 120
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(10, 45); $progress.Width = 1040; $progress.Height = 20
    $bar.Controls.AddRange(@($previewBtn, $applyBtn, $cancelBtn, $expertChk, $progress))
    $tweaksTab.Controls.Add($bar)
    $ui.Apply = $applyBtn; $ui.Cancel = $cancelBtn; $ui.Expert = $expertChk; $ui.Progress = $progress

    $dash = New-Object System.Windows.Forms.TabPage
    $dash.Text = 'Dashboard'
    $dashBox = New-Object System.Windows.Forms.TextBox
    $dashBox.Dock = 'Fill'; $dashBox.Multiline = $true; $dashBox.ReadOnly = $true; $dashBox.ScrollBars = 'Vertical'
    $dashBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $dashBox.Text = (Get-WinForgeDashboardText -Context $Context)
    $dash.Controls.Add($dashBox)

    $restore = New-Object System.Windows.Forms.TabPage
    $restore.Text = 'Restore'
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false
    $grid.SelectionMode = 'FullRowSelect'
    $ui.Grid = $grid
    Update-WinForgeHistoryGrid
    $undoBtn = New-Object System.Windows.Forms.Button
    $undoBtn.Text = 'Undo selected run'; $undoBtn.Dock = 'Bottom'; $undoBtn.Height = 32
    $undoBtn.Add_Click({ Invoke-WinForgeUiAction 'Undo' {
        $ui = $script:wfUi
        if ($null -eq $ui.Grid.CurrentRow) { return }
        $runId = [string]$ui.Grid.CurrentRow.Cells['RunId'].Value
        $plan = Invoke-WinForgeUndo -Context $ui.Context -RunId $runId -Preview
        if (-not $plan) { [void][System.Windows.Forms.MessageBox]::Show("Nothing left to undo in run $runId.", 'Undo'); return }
        $text = "Undo run ${runId}?`r`n`r`n" + ((Get-WinForgeUndoPlanText -Plan $plan) -join "`r`n")
        if ([System.Windows.Forms.MessageBox]::Show($text, 'Undo: current -> restored', 'YesNo') -ne 'Yes') { return }
        $r = Invoke-WinForgeUndo -Context $ui.Context -RunId $runId
        Update-WinForgeHistoryGrid
        [void][System.Windows.Forms.MessageBox]::Show(($r | Format-Table Id, Status, Reason -AutoSize | Out-String), 'Undo result')
    } })
    $restore.Controls.Add($grid); $restore.Controls.Add($undoBtn)

    $mon = New-Object System.Windows.Forms.TabPage
    $mon.Text = 'Monitor'
    $monBox = New-Object System.Windows.Forms.TextBox
    $monBox.Dock = 'Fill'; $monBox.Multiline = $true; $monBox.ReadOnly = $true; $monBox.ScrollBars = 'Both'; $monBox.WordWrap = $false
    $monBox.Font = New-Object System.Drawing.Font('Consolas', 8)
    $monBox.Text = (Get-WinForgeConnectionSnapshot -EstablishedOnly | Format-Table Process, PID, RemoteAddress, RemotePort, Class -AutoSize | Out-String)
    $mon.Controls.Add($monBox)

    $sec = New-Object System.Windows.Forms.TabPage
    $sec.Text = 'Security'
    $secBox = New-Object System.Windows.Forms.TextBox
    $secBox.Dock = 'Fill'; $secBox.Multiline = $true; $secBox.ReadOnly = $true
    $secBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $secBox.Text = ((Get-WinForgeSecurityPosture).PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }) -join "`r`n"
    $sec.Controls.Add($secBox)

    $tabs.TabPages.AddRange(@($tweaksTab, $dash, $restore, $mon, $sec))
    $form.Controls.Add($tabs)

    $previewBtn.Add_Click({ Invoke-WinForgeUiAction 'Preview' {
        $ids = Get-WinForgeCheckedTweakIds
        if (-not $ids) { [void][System.Windows.Forms.MessageBox]::Show('Select at least one tweak.'); return }
        $plan = Invoke-WinForgeOperation -Context $script:wfUi.Context -TweakId $ids -Preview
        [void][System.Windows.Forms.MessageBox]::Show(((Get-OperationPlanText -Plan $plan) -join "`r`n"), 'Preview: current -> new')
    } })

    $applyBtn.Add_Click({ Invoke-WinForgeUiAction 'Apply' {
        $ui = $script:wfUi
        $ids = Get-WinForgeCheckedTweakIds
        if (-not $ids) { [void][System.Windows.Forms.MessageBox]::Show('Select at least one tweak.'); return }
        $expert = $ui.Expert.Checked
        $typed = ''
        if ($expert) { $typed = [Microsoft.VisualBasic.Interaction]::InputBox('Type the Danger tweak ID to confirm, or leave blank for non-Danger only.', 'Expert confirmation') }
        # The confirmation shows the real plan (current -> new), not just a count.
        $plan = Invoke-WinForgeOperation -Context $ui.Context -TweakId $ids -Preview
        $text = "Apply these changes?`r`n`r`n" + ((Get-OperationPlanText -Plan $plan) -join "`r`n")
        if ([System.Windows.Forms.MessageBox]::Show($text, 'WinForge', 'YesNo') -ne 'Yes') { return }

        $ui.Apply.Enabled = $false; $ui.Cancel.Enabled = $true; $ui.Progress.Value = 0
        $ui.Runner = New-WinForgeApplyRunspace -Context $ui.Context -TweakId $ids -Expert:$expert -TypedConfirmation $typed
        $ui.Timer = New-Object System.Windows.Forms.Timer
        $ui.Timer.Interval = 250
        $ui.Timer.Add_Tick({ Invoke-WinForgeUiAction 'Progress' {
            $ui = $script:wfUi
            $s = $ui.Runner.Sync
            $ui.Progress.Value = [Math]::Min(100, [int](100 * $s.Progress / [Math]::Max(1, $s.Total)))
            if ($s.Done) { Complete-WinForgeApply }
        } })
        $ui.Timer.Start()
    } })

    $cancelBtn.Add_Click({ Invoke-WinForgeUiAction 'Cancel' {
        # Stops at the next tweak boundary; a tweak in progress is finished or rolled back.
        $ui = $script:wfUi
        if ($ui.ContainsKey('Runner') -and $ui.Runner) { $ui.Runner.Sync.Cancelled = $true; $ui.Cancel.Enabled = $false }
    } })

    $form.Add_FormClosing({
        $e = $args[1]
        $ui = $script:wfUi
        if ($ui.ContainsKey('Runner') -and $ui.Runner -and -not $ui.Runner.Sync.Done) {
            [void][System.Windows.Forms.MessageBox]::Show('A run is in progress. Press Cancel and wait for it to stop before closing.', 'WinForge')
            $e.Cancel = $true
        }
    })

    [void]$form.ShowDialog()
}
