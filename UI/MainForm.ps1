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

function Show-WinForgeMainForm {
    param($Context)

    $sys = Get-WinForgeSystemInfo
    $catalog = Get-WinForgeCatalog -Context $Context

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WinForge'
    $form.Size = New-Object System.Drawing.Size(1100, 720)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'

    $tweaksTab = New-Object System.Windows.Forms.TabPage
    $tweaksTab.Text = 'Tweaks'

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.SplitterDistance = 520

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Dock = 'Fill'; $list.CheckOnClick = $true
    $script:map = @{}
    foreach ($t in $catalog.tweaks) {
        $idx = $list.Items.Add(("[{0}] {1}  ({2})" -f $t.Risk, $t.Name, $t.Category))
        $script:map[$idx] = $t.Id
    }
    $split.Panel1.Controls.Add($list)

    $details = New-Object System.Windows.Forms.TextBox
    $details.Dock = 'Fill'; $details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
    $split.Panel2.Controls.Add($details)

    $list.Add_SelectedIndexChanged({
        if ($list.SelectedIndex -lt 0) { return }
        $id = $script:map[$list.SelectedIndex]
        $t = $catalog.tweaks | Where-Object { $_.Id -eq $id }
        $compat = Test-TweakCompatibility -Tweak $t -SystemInfo $sys
        $applied = if ($compat.Supported) { Test-TweakTargets -Tweak $t } else { $false }
        $before = ($t.Targets | ForEach-Object {
            $s = Get-TargetSnapshot -Target $_
            if ($s.Existed) { "$($_.Type): $($s.Kind) $($s.Value)" } else { "$($_.Type): (not present)" }
        }) -join "`r`n"
        $details.Text = @(
            "Id:           $($t.Id)"
            "Risk:         $($t.Risk)"
            "Reversible:   $($t.Reversible)"
            "NeedsRestart: $($t.NeedsRestart)"
            "Supported:    $($compat.Supported) $($compat.Reason)"
            "Applied:      $applied"
            "Description:  $($t.Description)"
            "Source:       $($t.SourceUrl)"
            ""
            "Current state:"
            $before
        ) -join "`r`n"
    })

    $tweaksTab.Controls.Add($split)

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 80
    $previewBtn = New-Object System.Windows.Forms.Button
    $previewBtn.Text = 'Preview'; $previewBtn.Location = New-Object System.Drawing.Point(10, 10); $previewBtn.Width = 100
    $applyBtn = New-Object System.Windows.Forms.Button
    $applyBtn.Text = 'Apply'; $applyBtn.Location = New-Object System.Drawing.Point(120, 10); $applyBtn.Width = 100
    $expertChk = New-Object System.Windows.Forms.CheckBox
    $expertChk.Text = 'Expert mode'; $expertChk.Location = New-Object System.Drawing.Point(240, 12); $expertChk.Width = 120
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(10, 45); $progress.Width = 1040; $progress.Height = 20

    $bar.Controls.AddRange(@($previewBtn, $applyBtn, $expertChk, $progress))
    $tweaksTab.Controls.Add($bar)

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
    $hist = Get-WinForgeHistory -Context $Context
    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add('RunId'); [void]$dt.Columns.Add('StartedUtc'); [void]$dt.Columns.Add('Applied'); [void]$dt.Columns.Add('Failed')
    foreach ($h in $hist) { [void]$dt.Rows.Add($h.RunId, $h.StartedUtc, $h.Applied, $h.Failed) }
    $grid.DataSource = $dt
    $undoBtn = New-Object System.Windows.Forms.Button
    $undoBtn.Text = 'Undo selected run'; $undoBtn.Dock = 'Bottom'; $undoBtn.Height = 32
    $undoBtn.Add_Click({
        if ($null -eq $grid.CurrentRow) { return }
        $runId = $grid.CurrentRow.Cells['RunId'].Value
        if ([System.Windows.Forms.MessageBox]::Show("Undo run $runId?", 'WinForge', 'YesNo') -ne 'Yes') { return }
        try { $r = Invoke-WinForgeUndo -Context $Context -RunId $runId }
        catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Undo failed'); return }
        [void][System.Windows.Forms.MessageBox]::Show(($r | Format-Table -AutoSize | Out-String), 'Undo result')
    })
    $restore.Controls.Add($grid); $restore.Controls.Add($undoBtn)

    $mon = New-Object System.Windows.Forms.TabPage
    $mon.Text = 'Monitor'
    $monBox = New-Object System.Windows.Forms.TextBox
    $monBox.Dock = 'Fill'; $monBox.Multiline = $true; $monBox.ReadOnly = $true; $monBox.ScrollBars = 'Vertical'
    $monBox.Font = New-Object System.Drawing.Font('Consolas', 8)
    $monBox.Text = (Get-WinForgeConnectionSnapshot | Format-Table -AutoSize | Out-String)
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

    $previewBtn.Add_Click({
        $ids = @(); foreach ($i in $list.CheckedIndices) { $ids += $script:map[[int]$i] }
        if (-not $ids) { [void][System.Windows.Forms.MessageBox]::Show('Select at least one tweak.'); return }
        try { $plan = Invoke-WinForgeOperation -Context $Context -TweakId $ids -Preview }
        catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Preview failed'); return }
        [void][System.Windows.Forms.MessageBox]::Show(((Get-OperationPlanText -Plan $plan) -join "`r`n"), 'Preview: current -> new')
    })

    $applyBtn.Add_Click({
        $ids = @(); foreach ($i in $list.CheckedIndices) { $ids += $script:map[[int]$i] }
        if (-not $ids) { [void][System.Windows.Forms.MessageBox]::Show('Select at least one tweak.'); return }
        $expert = $expertChk.Checked
        $typed = ''
        if ($expert) {
            $typed = [Microsoft.VisualBasic.Interaction]::InputBox('Type the Danger tweak ID to confirm, or leave blank for non-Danger only.', 'Expert confirmation')
        }
        # The confirmation shows the real plan (current -> new), not just a count.
        try { $plan = Invoke-WinForgeOperation -Context $Context -TweakId $ids -Preview }
        catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Preview failed'); return }
        $text = "Apply these changes?`r`n`r`n" + ((Get-OperationPlanText -Plan $plan) -join "`r`n")
        if ([System.Windows.Forms.MessageBox]::Show($text, 'WinForge', 'YesNo') -ne 'Yes') { return }

        # Event handlers run after this one returns, so state shared with the timer tick
        # lives in script scope; locals from this handler would be gone by then.
        $applyBtn.Enabled = $false
        $script:wfRunner = New-WinForgeApplyRunspace -Context $Context -TweakId $ids -Expert:$expert -TypedConfirmation $typed
        $script:wfTimer = New-Object System.Windows.Forms.Timer
        $script:wfTimer.Interval = 250
        $script:wfTimer.Add_Tick({
            $s = $script:wfRunner.Sync
            $progress.Value = [Math]::Min(100, [int](100 * $s.Progress / [Math]::Max(1, $s.Total)))
            if ($s.Done) {
                $script:wfTimer.Stop()
                $progress.Value = 100
                $applyBtn.Enabled = $true
                $script:wfRunner.PS.EndInvoke($script:wfRunner.Handle) | Out-Null
                $script:wfRunner.PS.Runspace.Close(); $script:wfRunner.PS.Dispose()
                if ($s.Error) { [void][System.Windows.Forms.MessageBox]::Show($s.Error, 'Apply failed') }
                else { [void][System.Windows.Forms.MessageBox]::Show(($s.Result | Format-Table -AutoSize | Out-String), 'Apply result') }
            }
        })
        $script:wfTimer.Start()
    })

    [void]$form.ShowDialog()
}