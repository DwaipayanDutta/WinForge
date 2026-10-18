# WinForge WPF front end. Layout and styling live in UI\WinForge.xaml (ported from the
# WinForge-UI.html design); this file only wires data and actions to the engine.
#
# Rules this UI keeps (from the design and the engine):
#  - Nothing changes without a preview of current -> new values and an explicit click.
#  - Danger tweaks are hidden unless Expert mode is on, are never picked by "select all",
#    and need their ID typed in the confirmation dialog. The engine enforces this too.
#  - Every number on screen is read from Windows or the catalog; anything that could not
#    be read is shown as unknown/unavailable, never as a guess.
#  - Slow or system-changing calls run in background jobs (UI\Background.ps1).

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:wf = $null
$script:WfArrow = [string][char]0x2192
$script:WfDot = [string][char]0x00B7

function ConvertTo-WfBrush { param([string] $Color) return ([Windows.Media.BrushConverter]::new()).ConvertFromString($Color) }

function Invoke-WfUi {
    # Every event handler body runs through here so an exception becomes a dialog instead
    # of an unhandled dispatcher exception.
    param([string] $Title, [scriptblock] $Action)
    try { & $Action }
    catch {
        Write-WinForgeLog -Level Error -Message "GUI ${Title}: $($_.Exception.Message)"
        Show-WfMessage -Title "$Title failed" -Lines @($_.Exception.Message) -IsError
    }
}

function New-WfText {
    param([string] $Text, [string] $Style, [double] $Size = 0, [string] $Color, [switch] $Bold, [switch] $Mono)
    $tb = New-Object Windows.Controls.TextBlock
    if ($Style) { $tb.Style = $script:wf.Window.FindResource($Style) }
    $tb.Text = $Text; $tb.TextWrapping = 'Wrap'
    if ($Size) { $tb.FontSize = $Size }
    if ($Color) { $tb.Foreground = ConvertTo-WfBrush $Color }
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    if ($Mono) { $tb.FontFamily = 'Consolas'; $tb.FontSize = 12 }
    return $tb
}

function New-WfTag {
    param([string] $Text, [ValidateSet('ok','warn','danger','neutral')] [string] $Kind = 'ok')
    $colors = @{ ok = @('#E1E9D6','#58734E'); warn = @('#F1DDC1','#8A6C3F'); danger = @('#F3CFC2','#9A4B3A'); neutral = @('#ECE5D6','#6F6A58') }
    $b = New-Object Windows.Controls.Border
    $b.Style = $script:wf.Window.FindResource('Tag')
    $b.Background = ConvertTo-WfBrush $colors[$Kind][0]
    $b.Child = New-WfText -Text $Text -Size 10 -Color $colors[$Kind][1]
    return $b
}

function New-WfRow {
    # One list row in the design's style: glyph tile, two lines of text, optional right side.
    param([string] $Glyph, [string] $Title, [string] $Sub, [System.Windows.UIElement[]] $Right, [switch] $NoTopLine)
    $row = New-Object Windows.Controls.Border
    $row.BorderBrush = ConvertTo-WfBrush '#E7DECA'
    $row.BorderThickness = if ($NoTopLine) { '0' } else { '0,1,0,0' }
    $row.Padding = '0,11'
    $g = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
    $tile = New-Object Windows.Controls.Border
    $tile.Width = 42; $tile.Height = 42; $tile.CornerRadius = 13; $tile.Background = ConvertTo-WfBrush '#E0E7D2'; $tile.Margin = '0,0,13,0'
    $gt = New-WfText -Text $Glyph -Size 17 -Color '#58734E'
    $gt.FontFamily = 'Segoe MDL2 Assets'; $gt.HorizontalAlignment = 'Center'; $gt.VerticalAlignment = 'Center'
    $tile.Child = $gt
    $text = New-Object Windows.Controls.StackPanel
    $text.VerticalAlignment = 'Center'
    [void]$text.Children.Add((New-WfText -Text $Title -Size 13 -Bold))
    if ($Sub) { $s = New-WfText -Text $Sub -Size 11 -Color '#7B8074'; $s.Margin = '0,3,0,0'; [void]$text.Children.Add($s) }
    $rightPanel = New-Object Windows.Controls.StackPanel
    $rightPanel.Orientation = 'Horizontal'; $rightPanel.VerticalAlignment = 'Center'
    foreach ($r in @($Right | Where-Object { $_ })) { [void]$rightPanel.Children.Add($r) }
    [Windows.Controls.Grid]::SetColumn($text, 1); [Windows.Controls.Grid]::SetColumn($rightPanel, 2)
    [void]$g.Children.Add($tile); [void]$g.Children.Add($text); [void]$g.Children.Add($rightPanel)
    $row.Child = $g
    return $row
}

function New-WfButton {
    param([string] $Text, [string] $Style = 'Link', [string] $Tag)
    $b = New-Object Windows.Controls.Button
    $b.Style = $script:wf.Window.FindResource($Style); $b.Content = $Text; $b.Tag = $Tag
    $b.Margin = '10,0,0,0'; $b.VerticalAlignment = 'Center'
    return $b
}

function ConvertTo-WfDataTable {
    param([object[]] $Rows, [string[]] $Columns)
    $dt = New-Object System.Data.DataTable
    foreach ($c in $Columns) { [void]$dt.Columns.Add($c) }
    foreach ($r in @($Rows | Where-Object { $_ })) {
        $vals = foreach ($c in $Columns) { $p = $r.PSObject.Properties[$c]; if ($p -and $null -ne $p.Value) { [string]$p.Value } else { '' } }
        [void]$dt.Rows.Add([object[]]@($vals))
    }
    return ,$dt
}

# ---------------------------------------------------------------- dialog

function Show-WfDialog {
    # Lines may be strings (rendered as plan lines) or UI elements. OnPrimary runs when the
    # primary button is clicked; the dialog closes first.
    param(
        [string] $Title, [object[]] $Lines, [string] $PrimaryText = 'OK', [scriptblock] $OnPrimary,
        [string] $SecondaryText, [bool] $PrimaryEnabled = $true, [string] $ConfirmId, [switch] $DangerPrimary,
        # Passed to OnPrimary as its only argument. Callbacks get their state this way, never
        # through closures: a GetNewClosure() scriptblock cannot see WinForge's functions.
        $Data
    )
    $c = $script:wf.C
    $c.DialogTitle.Text = $Title
    $c.DialogBody.Children.Clear()
    foreach ($l in @($Lines)) {
        if ($l -is [System.Windows.UIElement]) { [void]$c.DialogBody.Children.Add($l); continue }
        $s = [string]$l
        $color = if ($s -match ' DANGER: |^Blocked|Failed|Refused| SKIP: ') { '#9A4B3A' } elseif ($s -match ' NOTE: | REVERSIBLE: ') { '#8A6C3F' } else { '#3F463E' }
        $tb = New-WfText -Text $s -Mono -Color $color
        $tb.Margin = '0,0,0,6'
        [void]$c.DialogBody.Children.Add($tb)
    }
    $c.DialogPrimary.Content = $PrimaryText
    $c.DialogPrimary.Style = $script:wf.Window.FindResource($(if ($DangerPrimary) { 'Danger' } else { 'Primary' }))
    $c.DialogPrimary.Visibility = if ($PrimaryText) { 'Visible' } else { 'Collapsed' }
    $c.DialogSecondary.Content = $SecondaryText
    $c.DialogSecondary.Visibility = if ($SecondaryText) { 'Visible' } else { 'Collapsed' }
    $script:wf.DialogAction = $OnPrimary
    $script:wf.DialogData = $Data
    $script:wf.DialogConfirmId = $ConfirmId
    $script:wf.DialogPrimaryAllowed = $PrimaryEnabled
    if ($ConfirmId) {
        $c.ExpertConfirmPanel.Visibility = 'Visible'
        $c.ExpertConfirmLabel.Text = "This plan contains a Danger tweak. Type its ID to confirm: $ConfirmId"
        $c.ExpertConfirmBox.Text = ''
        $c.DialogPrimary.IsEnabled = $false
    } else {
        $c.ExpertConfirmPanel.Visibility = 'Collapsed'
        $c.DialogPrimary.IsEnabled = $PrimaryEnabled
    }
    $blur = New-Object Windows.Media.Effects.BlurEffect
    $blur.Radius = 6
    $c.Root.Effect = $blur
    $c.Overlay.Visibility = 'Visible'
    if ($ConfirmId) { [void]$c.ExpertConfirmBox.Focus() } elseif ($c.DialogPrimary.IsEnabled) { [void]$c.DialogPrimary.Focus() } else { [void]$c.DialogClose.Focus() }
}

function Show-WfMessage {
    param([string] $Title, [object[]] $Lines, [switch] $IsError)
    if (-not $script:wf -or -not $script:wf.C) { [void][Windows.MessageBox]::Show(($Lines -join "`n"), $Title); return }
    Show-WfDialog -Title $Title -Lines $Lines -PrimaryText 'Close'
}

function Close-WfDialog {
    $c = $script:wf.C
    $c.Overlay.Visibility = 'Collapsed'
    $c.Root.Effect = $null
    $script:wf.DialogAction = $null
}

# ---------------------------------------------------------------- background jobs

function Start-WfJob {
    param([string] $Name, [scriptblock] $Script, [hashtable] $JobArgs = @{}, [int] $Total = 1, [scriptblock] $OnDone, [switch] $Blocking)
    $job = Start-WinForgeJob -Context $script:wf.Context -Name $Name -Script $Script -JobArgs $JobArgs -Total $Total
    $job | Add-Member -NotePropertyName OnDone -NotePropertyValue $OnDone
    $job | Add-Member -NotePropertyName Blocking -NotePropertyValue ([bool]$Blocking)
    # OnDone is called as: & $OnDone $result $sync $JobArgs
    $job | Add-Member -NotePropertyName JobArgs -NotePropertyValue $JobArgs
    [void]$script:wf.Jobs.Add($job)
    if ($Blocking) { Set-WfBusy -Job $job }
    if (-not $script:wf.Timer.IsEnabled) { $script:wf.Timer.Start() }
    return $job
}

function Set-WfBusy {
    # A "blocking" job (apply, undo, install) disables every other change action and shows
    # progress and Cancel in the footer. Read-only jobs never block.
    param($Job)
    $c = $script:wf.C
    $script:wf.BusyJob = $Job
    $busy = [bool]$Job
    foreach ($b in $c.ReviewBtn, $c.HeroPreviewBtn, $c.UndoRunBtn, $c.ClearSelectionBtn) { $b.IsEnabled = -not $busy }
    foreach ($b in $script:wf.InstallButtons) { $b.IsEnabled = -not $busy }
    $c.RunProgress.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    $c.RunProgress.Value = 0
    $c.CancelRunBtn.Visibility = if ($busy -and $Job.Name -eq 'apply') { 'Visible' } else { 'Collapsed' }
    $c.CancelRunBtn.IsEnabled = $true
    if ($busy) { $c.SelectionLine.Text = "Working: $($Job.Name)..." } else { Update-WfSelectionLine }
    if (-not $busy) { $c.UndoRunBtn.IsEnabled = ($c.RunsGrid.SelectedIndex -ge 0) }
}

function Update-WfJobs {
    # DispatcherTimer tick: report progress, finish completed jobs on the UI thread.
    foreach ($job in @($script:wf.Jobs)) {
        $s = $job.Sync
        if ($job.Blocking) { $script:wf.C.RunProgress.Value = [Math]::Min(100, 100 * $s.Progress / [Math]::Max(1, $s.Total)) }
        if (-not $s.Done) { continue }
        [void]$script:wf.Jobs.Remove($job)
        Stop-WinForgeJobRunspace -Job $job
        if ($job.Blocking) { Set-WfBusy -Job $null }
        if ($s.Error) { Show-WfMessage -Title "$($job.Name) failed" -Lines @($s.Error) -IsError }
        elseif ($job.OnDone) { $result = $s.Result; $sync = $s; $done = $job; Invoke-WfUi $job.Name { & $done.OnDone $result $sync $done.JobArgs } }
    }
    if ($script:wf.Jobs.Count -eq 0) { $script:wf.Timer.Stop() }
}

# ---------------------------------------------------------------- navigation and selection

$script:WfPages = [ordered]@{
    Dashboard  = @('Dashboard', 'A calmer way to configure Windows.')
    Tweaks     = @('System tweaks', 'Every tweak in the catalog, checked against this PC.')
    Apps       = @('Applications', 'App bundles installed with winget (or Chocolatey if you already use it).')
    Profiles   = @('Profiles', 'Ready-made selections. You still review every change before it happens.')
    Security   = @('Security audit', 'What Windows reports about its protections. Read-only.')
    Monitoring = @('Monitoring', 'Which processes are connected where, right now.')
    History    = @('History & rollback', 'Every run is recorded and can be undone, per run.')
    Settings   = @('Settings', 'Expert mode and information about this installation.')
}

function Show-WfPage {
    param([string] $Name)
    $c = $script:wf.C
    foreach ($p in $script:WfPages.Keys) { $c["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $c.PageTitle.Text = $script:WfPages[$Name][0]; $c.PageSub.Text = $script:WfPages[$Name][1]
    $nav = $c["Nav$Name"]
    if ($nav -and -not $nav.IsChecked) { $nav.IsChecked = $true }
    $c.PageScroll.ScrollToTop()
    switch ($Name) {
        'Security'   { if (-not $script:wf.PostureLoaded) { Update-WfSecurity } }
        'History'    { Update-WfHistory }
        'Monitoring' { }
    }
}

function Get-WfVisibleTweaks {
    # Danger tweaks exist only in Expert mode.
    return @($script:wf.Catalog.tweaks | Where-Object { $script:wf.Expert -or $_.Risk -ne 'Danger' })
}

function Set-WfSelected {
    param([string] $Id, [bool] $On)
    if ($On) { [void]$script:wf.Selected.Add($Id) } else { [void]$script:wf.Selected.Remove($Id) }
}

function Update-WfSelectionLine {
    $c = $script:wf.C
    $n = $script:wf.Selected.Count
    $c.StatSelected.Text = [string]$n
    $danger = @($script:wf.Catalog.tweaks | Where-Object { $_.Risk -eq 'Danger' -and $script:wf.Selected.Contains($_.Id) }).Count
    $c.SelectionLine.Text = if ($n -eq 0) { 'Select tweaks to build a change plan. Nothing is applied until you review and confirm it.' }
        else { "$n tweak$(if ($n -ne 1) { 's' }) selected $($script:WfDot) $(if ($danger) { "$danger Danger $($script:WfDot) " })nothing applied yet." }
    $c.ReviewBtn.IsEnabled = ($n -gt 0 -and -not $script:wf.BusyJob)
}

function Get-WfStatusTag {
    param([string] $Id)
    $s = $script:wf.Status[$Id]
    if (-not $s) { return (New-WfTag 'Checking' 'neutral') }
    if ($s -eq 'applied') { return (New-WfTag 'Applied' 'ok') }
    if ($s -eq 'not applied') { return (New-WfTag 'Not applied' 'neutral') }
    if ($s -like 'unsupported*') { return (New-WfTag 'Not supported here' 'warn') }
    return (New-WfTag 'Unknown' 'neutral')
}

$script:WfCategoryGlyph = @{ Privacy = [char]0xE72E; Debloat = [char]0xE74D; Taskbar = [char]0xE75B; Explorer = [char]0xEC50; System = [char]0xE770; Security = [char]0xEA18; Start = [char]0xE8FC }

function New-WfTweakRow {
    param($Tweak, [switch] $Compact, [switch] $NoTopLine)
    $risk = switch ($Tweak.Risk) { 'Safe' { New-WfTag 'Safe' 'ok' } 'Caution' { New-WfTag 'Caution' 'warn' } default { New-WfTag 'Danger' 'danger' } }
    $sw = New-Object Windows.Controls.CheckBox
    $sw.Style = $script:wf.Window.FindResource('Switch')
    $sw.IsChecked = $script:wf.Selected.Contains($Tweak.Id)
    $sw.Tag = $Tweak.Id; $sw.Margin = '12,0,0,0'
    [Windows.Automation.AutomationProperties]::SetName($sw, "Select $($Tweak.Name)")
    $unsupported = ([string]$script:wf.Status[$Tweak.Id]) -like 'unsupported*'
    if ($unsupported) { $sw.IsEnabled = $false; $sw.ToolTip = $script:wf.Status[$Tweak.Id] }
    $sw.Add_Click({
        $id = [string]$this.Tag; $on = [bool]$this.IsChecked
        Invoke-WfUi 'Select' { Set-WfSelected -Id $id -On $on; Update-WfSelectionLine; Sync-WfSwitches -Id $id -On $on }
    })
    $glyph = $script:WfCategoryGlyph[[string]$Tweak.Category]; if (-not $glyph) { $glyph = [char]0xE713 }
    $sub = if ($Compact) { "$($Tweak.Category) $($script:WfDot) $(if ($Tweak.Reversible -eq 'full') { 'fully reversible' } else { "$($Tweak.Reversible)ly reversible" })" }
           else { "$($Tweak.Category) $($script:WfDot) $($Tweak.Description)" }
    $right = if ($Compact) { @((Get-WfStatusTag $Tweak.Id), $sw) } else { @($risk, (Get-WfStatusTag $Tweak.Id), $sw) }
    $row = New-WfRow -Glyph ([string]$glyph) -Title $Tweak.Name -Sub $sub -Right $right -NoTopLine:$NoTopLine
    $row.Tag = $Tweak.Id; $row.Cursor = 'Hand'; $row.Background = [Windows.Media.Brushes]::Transparent
    $row.Add_MouseLeftButtonUp({ $id = [string]$this.Tag; Invoke-WfUi 'Details' { Show-WfTweakDetail -Id $id } })
    return $row
}

function Sync-WfSwitches {
    # The same tweak can appear on the dashboard and the tweaks page; keep both in step.
    param([string] $Id, [bool] $On)
    foreach ($panel in $script:wf.C.EssentialsList, $script:wf.C.TweakList) {
        foreach ($row in $panel.Children) {
            if ($row.Tag -ne $Id) { continue }
            $sw = $row.Child.Children[2].Children | Where-Object { $_ -is [Windows.Controls.CheckBox] }
            foreach ($s in @($sw)) { $s.IsChecked = $On }
        }
    }
}

function Update-WfTweakList {
    $c = $script:wf.C
    $q = $c.SearchBox.Text.Trim().ToLower()
    $cat = [string]$c.FilterCategory.SelectedItem
    $risk = [string]$c.FilterRisk.SelectedItem
    $items = Get-WfVisibleTweaks | Where-Object {
        (-not $q -or ("$($_.Name) $($_.Description) $($_.Id) $($_.Category)").ToLower().Contains($q)) -and
        ($cat -eq 'All categories' -or $_.Category -eq $cat) -and
        ($risk -eq 'All risks' -or $_.Risk -eq $risk) -and
        (-not $c.FilterNotApplied.IsChecked -or $script:wf.Status[$_.Id] -eq 'not applied') -and
        (-not $c.FilterSelected.IsChecked -or $script:wf.Selected.Contains($_.Id))
    }
    $c.TweakList.Children.Clear()
    $first = $true
    foreach ($t in @($items)) { [void]$c.TweakList.Children.Add((New-WfTweakRow -Tweak $t -NoTopLine:$first)); $first = $false }
    $all = @(Get-WfVisibleTweaks).Count
    $c.TweakCountText.Text = if (@($items).Count) { "Showing $(@($items).Count) of $all tweaks$(if (-not $script:wf.Expert) { ' (Danger tweaks hidden; turn on Expert mode in Settings)' })" } else { 'No tweaks match these filters.' }
}

function Update-WfEssentials {
    $c = $script:wf.C
    $c.EssentialsList.Children.Clear()
    $ids = @(($script:wf.Profiles | Where-Object Id -eq 'Minimal').TweakIds) | Select-Object -First 6
    $first = $true
    foreach ($id in $ids) {
        $t = $script:wf.Catalog.tweaks | Where-Object Id -eq $id
        if ($t) { [void]$c.EssentialsList.Children.Add((New-WfTweakRow -Tweak $t -Compact -NoTopLine:$first)); $first = $false }
    }
    $more = New-WfButton -Text "All tweaks $($script:WfArrow)"
    $more.Margin = '0,10,0,0'; $more.HorizontalAlignment = 'Left'
    $more.Add_Click({ Invoke-WfUi 'Navigate' { Show-WfPage 'Tweaks' } })
    [void]$c.EssentialsList.Children.Add($more)
}

function Show-WfTweakDetail {
    param([string] $Id)
    $c = $script:wf.C
    $t = $script:wf.Catalog.tweaks | Where-Object Id -eq $Id
    if (-not $t) { return }
    if ($c.PageTweaks.Visibility -ne 'Visible') { Show-WfPage 'Tweaks' }
    $c.DetailTitle.Text = $t.Name
    $c.DetailTags.Children.Clear()
    $riskKind = switch ($t.Risk) { 'Safe' { 'ok' } 'Caution' { 'warn' } default { 'danger' } }
    [void]$c.DetailTags.Children.Add((New-WfTag $t.Risk $riskKind))
    [void]$c.DetailTags.Children.Add((New-WfTag "Reversible: $($t.Reversible)" $(if ($t.Reversible -eq 'full') { 'ok' } else { 'warn' })))
    if ($t.NeedsRestart) { [void]$c.DetailTags.Children.Add((New-WfTag 'Restart needed' 'neutral')) }
    [void]$c.DetailTags.Children.Add((Get-WfStatusTag $t.Id))
    $profilesWith = @($script:wf.Profiles | Where-Object { $_.TweakIds -contains $t.Id } | ForEach-Object Id)
    $c.DetailDesc.Text = $t.Description + $(if ($profilesWith) { "`n`nIn profiles: $($profilesWith -join ', ')" } else { "`n`nNot in any profile." })
    $c.DetailSource.Text = if (Get-TweakProperty $t 'SourceUrl') { "Source: $($t.SourceUrl)" } else { '' }
    $c.DetailPlan.Text = 'Reading current state...'
    $script:wf.DetailId = $t.Id
    Start-WfJob -Name 'detail' -JobArgs @{ Id = $t.Id } -Script {
        $cat = Get-WinForgeCatalog -Context $Context
        $tw = Get-WinForgeTweak -Id $JobArgs.Id -Catalog $cat
        (Get-OperationPlanText -Plan (New-OperationPlan -Tweaks @($tw) -SystemInfo (Get-WinForgeSystemInfo))) -join "`n"
    } -OnDone {
        param($r, $sync, $a)
        # Ignore a late answer for a tweak the user has already moved away from.
        if ($script:wf.DetailId -eq $a.Id) { $script:wf.C.DetailPlan.Text = $r }
    } | Out-Null
}

# ---------------------------------------------------------------- data refresh

function Update-WfStatus {
    # Reads the applied/supported state of every tweak in the background.
    $script:wf.C.StatCompat.Text = 'Checking...'
    Start-WfJob -Name 'status' -Script {
        $sys = Get-WinForgeSystemInfo
        $cat = Get-WinForgeCatalog -Context $Context
        $out = @{}
        foreach ($t in $cat.tweaks) { $out[$t.Id] = Get-WinForgeTweakStatusText -Tweak $t -SystemInfo $sys }
        $out
    } -OnDone {
        param($r)
        $script:wf.Status = $r
        $visible = Get-WfVisibleTweaks
        $supported = @($visible | Where-Object { -not (([string]$r[$_.Id]) -like 'unsupported*') }).Count
        $applied = @($visible | Where-Object { $r[$_.Id] -eq 'applied' }).Count
        $script:wf.C.StatCompat.Text = "$supported of $(@($visible).Count)"
        $script:wf.C.StatCompatHint.Text = "tweaks supported on this PC $($script:WfDot) $applied already applied"
        Update-WfEssentials; Update-WfTweakList
        $script:wf.StatusLoaded = $true
    } | Out-Null
}

function Update-WfSecurity {
    $c = $script:wf.C
    $c.SecurityList.Children.Clear()
    [void]$c.SecurityList.Children.Add((New-WfText -Text 'Reading from Windows...' -Style 'Sub'))
    Start-WfJob -Name 'security' -Script { [pscustomobject]@{ Posture = Get-WinForgeSecurityPosture; Honesty = Get-WinForgeTelemetryHonesty } } -OnDone {
        param($r)
        $c = $script:wf.C
        $script:wf.PostureLoaded = $true
        $c.SecurityList.Children.Clear()
        $labels = [ordered]@{
            Antivirus = @('Antivirus registered with Windows', [char]0xEA18)
            DefenderRealTime = @('Defender real-time protection', [char]0xEA18); DefenderMode = @('Defender running mode', [char]0xEA18)
            TamperProtection = @('Tamper Protection', [char]0xE72E); FirewallProfiles = @('Firewall profiles', [char]0xE968)
            SmartScreenPolicy = @('SmartScreen policy', [char]0xE8A1); SmartScreenSetting = @('SmartScreen setting', [char]0xE8A1)
            SystemDriveProtection = @('System drive encryption (BitLocker)', [char]0xE72E)
        }
        $first = $true
        foreach ($p in $r.Posture.PSObject.Properties) {
            $l = $labels[$p.Name]; if (-not $l) { $l = @($p.Name, [char]0xE946) }
            $v = [string]$p.Value
            $kind = if ($v -match '^Unavailable|Not configured|Not set') { 'neutral' } elseif ($v -match '^(True|On|Normal)$') { 'ok' } elseif ($v -match '^(False|Off)$|=False') { 'warn' } else { 'neutral' }
            $tagText = if ($v.Length -gt 34) { $v.Substring(0, 31) + '...' } else { $v }
            $tag = New-WfTag $tagText $kind; $tag.ToolTip = $v
            [void]$c.SecurityList.Children.Add((New-WfRow -Glyph ([string]$l[1]) -Title $l[0] -Sub $v -Right @($tag) -NoTopLine:$first))
            $first = $false
        }
        $c.PrivacyNote.Text = "$($r.Honesty.Edition): $($r.Honesty.PolicyNote)"
        # Which antivirus is actually protecting the PC: Defender in passive mode with another
        # product on is healthy, and saying "Defender off" alone would mislead.
        $rt = [string]$r.Posture.DefenderRealTime
        $active = @(([string](Get-TweakProperty $r.Posture 'Antivirus')) -split '; ' | Where-Object { $_ -match '=on$' } | ForEach-Object { $_ -replace '=on$', '' })
        $other = @($active | Where-Object { $_ -notmatch 'Defender' })
        $c.StatSecurity.Text = if ($rt -eq 'True') { 'Defender on' } elseif ($other) { "$($other[0]) on" } elseif ($rt -eq 'False') { 'No active AV' } else { 'Unavailable' }
        $fw = [string]$r.Posture.FirewallProfiles
        $on = ([regex]::Matches($fw, '=True')).Count; $all = ([regex]::Matches($fw, '=')).Count
        $parts = @()
        if ($other -and $rt -ne 'True') { $parts += "Defender: $($r.Posture.DefenderMode)" }
        $parts += if ($all) { "firewall on for $on of $all profiles" } else { 'firewall state unavailable' }
        $c.StatSecurityHint.Text = ($parts -join " $($script:WfDot) ") + " $($script:WfDot) read from Windows"
    } | Out-Null
}

function Update-WfHistory {
    $c = $script:wf.C
    $hist = @(Get-WinForgeHistory -Context $script:wf.Context)
    $script:wf.History = $hist
    $c.RunsGrid.ItemsSource = (ConvertTo-WfDataTable -Rows $hist -Columns @('RunId','StartedUtc','Profile','State','Applied','Failed','Restored')).DefaultView
    $c.InstallsGrid.ItemsSource = (ConvertTo-WfDataTable -Rows @(Get-WinForgeInstallHistory -Context $script:wf.Context) -Columns @('InstallId','StartedUtc','Bundle','RestorePoint','Installed','Failed')).DefaultView
    $c.UndoRunBtn.IsEnabled = $false
    $c.RunDetail.Text = if ($hist) { 'Select a run to see each tweak, its status and whether it was undone.' } else { 'No runs recorded yet. Runs appear here after you apply changes.' }

    $undoable = @($hist | Where-Object { $_.Applied -gt $_.Restored }).Count
    $c.StatRollback.Text = [string]$undoable
    $c.StatRollbackHint.Text = if ($hist) { "of $($hist.Count) recorded run$(if ($hist.Count -ne 1) { 's' }) can still be undone" } else { 'No runs recorded on this PC yet' }

    $c.RecentList.Children.Clear()
    if (-not $hist) {
        [void]$c.RecentList.Children.Add((New-WfRow -Glyph ([string][char]0xE81C) -Title 'No system changes recorded' -Sub 'Selections are not history; only confirmed runs are recorded.' -NoTopLine))
    } else {
        $first = $true
        foreach ($h in $hist | Select-Object -First 3) {
            $tag = if ($h.State -eq 'Completed' -and $h.Failed -eq 0) { New-WfTag $h.State 'ok' } else { New-WfTag $h.State 'warn' }
            [void]$c.RecentList.Children.Add((New-WfRow -Glyph ([string][char]0xE81C) -Title $(if ($h.Profile) { "Profile $($h.Profile)" } else { 'Selected tweaks' }) `
                -Sub "$($h.StartedUtc) $($script:WfDot) applied $($h.Applied), failed $($h.Failed), restored $($h.Restored)" -Right @($tag) -NoTopLine:$first))
            $first = $false
        }
    }
}

function Show-WfRunDetail {
    $c = $script:wf.C
    $i = $c.RunsGrid.SelectedIndex
    if ($i -lt 0 -or $i -ge @($script:wf.History).Count) { $c.UndoRunBtn.IsEnabled = $false; return }
    $runId = @($script:wf.History)[$i].RunId
    $rec = Get-RunRecord -Context $script:wf.Context -RunId $runId
    $lines = foreach ($t in @($rec.Tweaks)) {
        $undo = if ($t.PSObject.Properties['UndoStatus'] -and $t.UndoStatus) { "  [undo: $($t.UndoStatus)]" } else { '' }
        "{0,-40} {1}{2}{3}" -f $t.Id, $t.Status, $undo, $(if ($t.Reason) { "  $($t.Reason)" })
    }
    $c.RunDetail.Text = "Run $runId $($script:WfDot) $($rec.State) $($script:WfDot) Windows $($rec.Windows.Build) $($rec.Windows.Edition)`n`n" + ($lines -join "`n")
    $c.UndoRunBtn.IsEnabled = -not $script:wf.BusyJob
}

function Update-WfDashboardStatic {
    $c = $script:wf.C
    $sys = $script:wf.Sys
    $c.MachineTitle.Text = "Windows build $($sys.Build)"
    $c.MachineSub.Text = "$($sys.Edition) ($($sys.EditionId)) $($script:WfDot) $($sys.Arch)`n$(if ($sys.Elevated) { 'Administrator' } else { 'Standard rights (preview only)' })"
    $c.VersionText.Text = "WinForge $($script:wf.Context.Version)"
    $c.NoticeText.Text = "Live data from this PC $($script:WfDot) catalog of $(@($script:wf.Catalog.tweaks).Count) tweaks $($script:WfDot) no telemetry; network only for app installs, update checks and optional DNS lookups"
    $c.ElevationBanner.Visibility = if ($sys.Elevated) { 'Collapsed' } else { 'Visible' }

    $c.InsightsList.Children.Clear()
    # Leading commas keep each row an array; without them @() flattens the rows together.
    $rows = @(
        ,@([char]0xE770, 'Windows', "Build $($sys.Build) $($script:WfDot) $($sys.Edition) ($($sys.EditionId)) $($script:WfDot) $($sys.Arch)")
        ,@([char]0xE7EF, 'Rights', $(if ($sys.Elevated) { 'Running as administrator' } else { 'Not elevated: preview and read-only views only' }))
        ,@([char]0xE968, 'Management', $(if ($sys.Managed) { "Managed ($($sys.ManagedReason)): only Safe tweaks will apply" } else { 'Not domain-joined or MDM-enrolled' }))
        ,@([char]0xE8B7, 'State folder', "$($script:wf.Context.StateRoot)$(if (Get-TweakProperty $script:wf.Context 'StateProtected') { ' (admin-only)' })")
    )
    $first = $true
    foreach ($r in $rows) { [void]$c.InsightsList.Children.Add((New-WfRow -Glyph ([string]$r[0]) -Title $r[1] -Sub $r[2] -NoTopLine:$first)); $first = $false }

    foreach ($panel in $c.DashProfilesList, $c.ProfilesList) { $panel.Children.Clear() }
    $first = $true
    foreach ($p in $script:wf.Profiles) {
        $tw = @($script:wf.Catalog.tweaks | Where-Object { $p.TweakIds -contains $_.Id })
        $sel = New-WfButton -Text "Select $($script:WfArrow)" -Tag $p.Id
        $sel.Add_Click({ $pid_ = [string]$this.Tag; Invoke-WfUi 'Profile' { Select-WfProfile -Id $pid_ -Review } })
        [void]$c.DashProfilesList.Children.Add((New-WfRow -Glyph ([string][char]0xE8F1) -Title $p.Name -Sub "$($tw.Count) tweaks $($script:WfDot) $($p.Description)" -Right @($sel) -NoTopLine:$first))
        $first = $false

        $card = New-Object Windows.Controls.Border
        $card.Style = $script:wf.Window.FindResource('Card')
        $sp = New-Object Windows.Controls.StackPanel
        $head = New-Object Windows.Controls.DockPanel
        $caution = @($tw | Where-Object Risk -eq 'Caution').Count
        $partial = @($tw | Where-Object Reversible -ne 'full').Count
        $tags = New-Object Windows.Controls.StackPanel; $tags.Orientation = 'Horizontal'
        [void]$tags.Children.Add((New-WfTag "$($tw.Count) tweaks" 'ok'))
        if ($caution) { [void]$tags.Children.Add((New-WfTag "$caution Caution" 'warn')) }
        if ($partial) { [void]$tags.Children.Add((New-WfTag "$partial not fully reversible" 'warn')) }
        [Windows.Controls.DockPanel]::SetDock($tags, 'Right'); [void]$head.Children.Add($tags)
        [void]$head.Children.Add((New-WfText -Text $p.Name -Style 'H2'))
        [void]$sp.Children.Add($head)
        $d = New-WfText -Text $p.Description -Style 'Sub' -Size 13; $d.Margin = '0,8,0,12'; [void]$sp.Children.Add($d)
        $list = New-WfText -Text (($tw | ForEach-Object { $_.Name }) -join "  $($script:WfDot)  ") -Style 'Sub'; $list.Margin = '0,0,0,14'; [void]$sp.Children.Add($list)
        $btns = New-Object Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'
        $b1 = New-WfButton -Text 'Review this profile' -Style 'Primary' -Tag $p.Id; $b1.Margin = '0,0,10,0'
        $b1.Add_Click({ $pid_ = [string]$this.Tag; Invoke-WfUi 'Profile' { Select-WfProfile -Id $pid_ -Review } })
        $b2 = New-WfButton -Text 'Select and customise' -Style 'Secondary' -Tag $p.Id; $b2.Margin = '0'
        $b2.Add_Click({ $pid_ = [string]$this.Tag; Invoke-WfUi 'Profile' { Select-WfProfile -Id $pid_; $script:wf.C.FilterSelected.IsChecked = $true; Show-WfPage 'Tweaks'; Update-WfTweakList } })
        [void]$btns.Children.Add($b1); [void]$btns.Children.Add($b2)
        [void]$sp.Children.Add($btns)
        $card.Child = $sp
        [void]$c.ProfilesList.Children.Add($card)
    }

    $c.AboutText.Text = @(
        "Version       $($script:wf.Context.Version)"
        "Program       $($script:wf.Context.Root)"
        "Catalog       $($script:wf.Context.CatalogRoot) ($(@($script:wf.Catalog.tweaks).Count) tweaks)"
        "State folder  $($script:wf.Context.StateRoot)"
        "Protected     $(if (Get-TweakProperty $script:wf.Context 'StateProtected') { 'yes (SYSTEM and Administrators only)' } elseif ($script:wf.Context.IsPortable) { 'no (portable mode)' } else { 'no' })"
        "Elevated      $($sys.Elevated)"
    ) -join "`n"
}

function Select-WfProfile {
    param([string] $Id, [switch] $Review)
    $p = $script:wf.Profiles | Where-Object Id -eq $Id
    $script:wf.Selected.Clear()
    foreach ($t in @($p.TweakIds)) { if (-not (([string]$script:wf.Status[$t]) -like 'unsupported*')) { [void]$script:wf.Selected.Add($t) } }
    Update-WfSelectionLine; Update-WfEssentials; Update-WfTweakList
    if ($Review) { Show-WfReview -ProfileName $Id }
}

function Update-WfBundles {
    $c = $script:wf.C
    $c.BundlesList.Children.Clear()
    $script:wf.InstallButtons = New-Object System.Collections.ArrayList
    $script:wf.AppTags = @{}
    foreach ($b in $script:wf.Bundles) {
        $card = New-Object Windows.Controls.Border
        $card.Style = $script:wf.Window.FindResource('Card')
        $sp = New-Object Windows.Controls.StackPanel
        $head = New-Object Windows.Controls.DockPanel
        $btns = New-Object Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'
        $apps = @($script:wf.Apps | Where-Object { $b.Apps -contains $_.Id })
        if ($apps) {
            $check = New-WfButton -Text 'Check status' -Style 'Secondary' -Tag $b.Id; $check.Margin = '0,0,10,0'
            $check.Add_Click({ $bid = [string]$this.Tag; Invoke-WfUi 'Check' { Invoke-WfBundle -BundleId $bid -DryRun } })
            $inst = New-WfButton -Text 'Install...' -Style 'Primary' -Tag $b.Id; $inst.Margin = '0'
            $inst.Add_Click({ $bid = [string]$this.Tag; Invoke-WfUi 'Install' { Invoke-WfBundle -BundleId $bid } })
            [void]$script:wf.InstallButtons.Add($inst)
            [void]$btns.Children.Add($check); [void]$btns.Children.Add($inst)
        }
        [Windows.Controls.DockPanel]::SetDock($btns, 'Right'); [void]$head.Children.Add($btns)
        [void]$head.Children.Add((New-WfText -Text $b.Name -Style 'H2'))
        [void]$sp.Children.Add($head)
        $notes = Get-TweakProperty $b 'Notes'
        if ($notes) { $n = New-WfText -Text $notes -Style 'Sub' -Size 12; $n.Margin = '0,8,0,0'; [void]$sp.Children.Add($n) }
        if (-not $apps) { $e = New-WfText -Text 'No apps in this bundle yet.' -Style 'Sub'; $e.Margin = '0,8,0,0'; [void]$sp.Children.Add($e) }
        $first = $true
        foreach ($a in $apps) {
            $tag = New-WfTag 'Not checked' 'neutral'
            $script:wf.AppTags["$($b.Id)/$($a.Id)"] = $tag
            $ids = @(foreach ($pr in $a.Providers.PSObject.Properties) { if ($pr.Value) { "$($pr.Name): $($pr.Value)" } }) -join "  $($script:WfDot)  "
            $row = New-WfRow -Glyph ([string][char]0xE71D) -Title $a.Name -Sub "$($a.Category) $($script:WfDot) $ids" -Right @($tag) -NoTopLine:$first
            if ($first) { $row.Margin = '0,10,0,0' }
            [void]$sp.Children.Add($row); $first = $false
        }
        $card.Child = $sp
        [void]$c.BundlesList.Children.Add($card)
    }
    Start-WfJob -Name 'providers' -Script { Get-WinForgeProviders } -OnDone {
        param($r)
        $w = if ($r.winget) { "winget $($r.winget)" } else { 'winget not found' }
        $ch = if ($r.choco) { "Chocolatey $($r.choco)" } else { 'Chocolatey not installed' }
        $script:wf.C.ProvidersText.Text = "$w $($script:WfDot) $ch"
    } | Out-Null
}

function Set-WfAppTags {
    param([string] $BundleId, $Report)
    foreach ($r in @($Report)) {
        $tag = $script:wf.AppTags["$BundleId/$($r.Id)"]
        if (-not $tag) { continue }
        $kind = switch -Regex ($r.Status) { '^(AlreadyInstalled|InstalledVerified)$' { 'ok' } '^WouldInstall$' { 'neutral' } default { 'warn' } }
        $label = switch ($r.Status) { 'AlreadyInstalled' { 'Installed' } 'WouldInstall' { 'Not installed' } 'InstalledVerified' { 'Installed now' } default { $r.Status } }
        $tag.Background = ConvertTo-WfBrush $(switch ($kind) { 'ok' { '#E1E9D6' } 'warn' { '#F1DDC1' } default { '#ECE5D6' } })
        $tag.Child.Text = $label
        $tag.ToolTip = (Get-TweakProperty $r 'Reason')
    }
}

$script:WfBundleJob = { Install-WinForgeBundle -Context $Context -BundleId $JobArgs.Bundle -DryRun:$JobArgs.DryRun -AllowChocoFallback:$JobArgs.Fallback }

function Invoke-WfBundle {
    # Check: dry run only. Install: dry run first, show exactly what would be installed,
    # and install only after the user confirms.
    param([string] $BundleId, [switch] $DryRun)
    $fallback = [bool]$script:wf.C.ChocoFallback.IsChecked
    $onCheck = if ($DryRun) {
        { param($r, $sync, $a) Set-WfAppTags -BundleId $a.Bundle -Report $r }
    } else {
        {
            param($r, $sync, $a)
            Set-WfAppTags -BundleId $a.Bundle -Report $r
            $todo = @($r | Where-Object Status -eq 'WouldInstall')
            $lines = @($r | ForEach-Object { "{0,-14} {1,-18} {2}" -f $_.Id, $_.Status, $(if (Get-TweakProperty $_ 'Package') { "$($_.Provider) $($_.Package)" } else { Get-TweakProperty $_ 'Reason' }) })
            if (-not $todo) { Show-WfMessage -Title "Bundle $($a.Bundle)" -Lines (@('Nothing to install: every app is already installed or has no provider.', '') + $lines); return }
            $lines += ''
            $lines += 'Installers are downloaded and run by the package manager. WinForge takes a System Restore point first when Windows allows it.'
            $elev = [bool]$script:wf.Sys.Elevated
            if (-not $elev) { $lines += 'Installing needs administrator rights: close this window and start WinForge.bat.' }
            Show-WfDialog -Title "Install $($todo.Count) app$(if ($todo.Count -ne 1) { 's' }) from $($a.Bundle)?" -Lines $lines `
                -PrimaryText "Install $($todo.Count)" -SecondaryText 'Cancel' -PrimaryEnabled $elev -Data $a.Bundle -OnPrimary {
                    param($bundle)
                    Start-WfJob -Name 'install' -Blocking -JobArgs @{ Bundle = $bundle; DryRun = $false; Fallback = [bool]$script:wf.C.ChocoFallback.IsChecked } -Script $script:WfBundleJob -OnDone {
                        param($res, $sync, $ja)
                        Set-WfAppTags -BundleId $ja.Bundle -Report $res
                        Update-WfHistory
                        Show-WfMessage -Title 'Install result' -Lines @($res | ForEach-Object { "{0,-14} {1,-20} {2}" -f $_.Id, $_.Status, (Get-TweakProperty $_ 'Reason') })
                    } | Out-Null
                }
        }
    }
    Start-WfJob -Name 'check apps' -JobArgs @{ Bundle = $BundleId; DryRun = $true; Fallback = $fallback } -Script $script:WfBundleJob -OnDone $onCheck | Out-Null
}

# ---------------------------------------------------------------- review, apply, undo

function Show-WfReview {
    $ids = @($script:wf.Selected)
    if (-not $ids) { Show-WfMessage -Title 'Nothing selected' -Lines @('Select at least one tweak, or pick a profile.'); return }
    $script:wf.C.SelectionLine.Text = 'Building the change plan from this PC...'
    Start-WfJob -Name 'preview' -JobArgs @{ Ids = $ids } -Script {
        $plan = Invoke-WinForgeOperation -Context $Context -TweakId $JobArgs.Ids -Preview 6>$null
        [pscustomobject]@{
            Lines = @(Get-OperationPlanText -Plan $plan)
            Supported = @($plan | Where-Object Supported).Count
            Danger = @($plan | Where-Object { $_.Supported -and $_.Risk -eq 'Danger' } | ForEach-Object Id)
            Total = @($plan).Count
        }
    } -OnDone {
        param($r, $sync, $a)
        Update-WfSelectionLine
        $elev = [bool]$script:wf.Sys.Elevated
        $danger = @($r.Danger)
        $ok = $r.Supported -gt 0 -and $elev -and $danger.Count -le 1
        $extra = @()
        if (-not $elev) { $extra += 'Applying needs administrator rights: close this window and start WinForge.bat.' }
        if ($danger.Count -gt 1) { $extra += 'Danger tweaks must be applied one at a time. Deselect all but one.' }
        if ($r.Supported -eq 0) { $extra += 'None of the selected tweaks can be applied on this PC.' }
        $extra += "$($r.Supported) of $($r.Total) selected tweak$(if ($r.Total -ne 1) { 's' }) can be applied here. Every change is recorded and can be undone from History."
        $confirm = if ($danger.Count -eq 1) { [string]$danger[0] } else { $null }
        Show-WfDialog -Title "Change plan: current $($script:WfArrow) new" -Lines (@($r.Lines) + @('') + $extra) `
            -PrimaryText "Apply $($r.Supported) change$(if ($r.Supported -ne 1) { 's' })" -SecondaryText 'Back' `
            -PrimaryEnabled $ok -ConfirmId $confirm -DangerPrimary:([bool]$confirm) `
            -Data @{ Ids = $a.Ids; Typed = $confirm } -OnPrimary { param($d) Start-WfApply -Ids $d.Ids -TypedConfirmation $d.Typed }
    } | Out-Null
}

function Start-WfApply {
    param([string[]] $Ids, [string] $TypedConfirmation)
    Start-WfJob -Name 'apply' -Blocking -Total $Ids.Count -JobArgs @{ Ids = $Ids; Typed = $TypedConfirmation; Expert = [bool]$TypedConfirmation } -Script {
        Invoke-WinForgeOperation -Context $Context -TweakId $JobArgs.Ids -Force -Expert:$JobArgs.Expert -TypedConfirmation $JobArgs.Typed -CancelToken $sync 6>$null
    } -OnDone {
        param($r, $sync)
        $script:wf.Selected.Clear()
        Update-WfSelectionLine; Update-WfHistory; Update-WfStatus
        $title = if ($sync.Cancelled) { 'Run cancelled: finished tweaks are recorded and can be undone' } else { 'Apply result' }
        $lines = @($r | ForEach-Object { "{0,-40} {1,-16} {2}" -f $_.Id, $_.Status, $_.Reason })
        if (@($r | Where-Object Status -eq 'AwaitingRestart')) { $lines += ''; $lines += 'Some changes finish after a restart.' }
        Show-WfMessage -Title $title -Lines $lines
    } | Out-Null
}

function Start-WfUndo {
    $i = $script:wf.C.RunsGrid.SelectedIndex
    if ($i -lt 0) { return }
    $runId = [string]@($script:wf.History)[$i].RunId
    Start-WfJob -Name 'undo preview' -JobArgs @{ RunId = $runId } -Script {
        $plan = Invoke-WinForgeUndo -Context $Context -RunId $JobArgs.RunId -Preview
        [pscustomobject]@{ Lines = @(Get-WinForgeUndoPlanText -Plan $plan); Restorable = @($plan | Where-Object Action -eq 'Restore').Count; Count = @($plan).Count }
    } -OnDone {
        param($r, $sync, $a)
        if ($r.Count -eq 0) { Show-WfMessage -Title "Run $($a.RunId)" -Lines @('Nothing left to undo in this run.'); return }
        $elev = [bool]$script:wf.Sys.Elevated
        $lines = @($r.Lines) + @('')
        if (-not $elev) { $lines += 'Undo needs administrator rights: close this window and start WinForge.bat.' }
        $lines += 'After restoring, WinForge reads every value back and reports anything that does not match.'
        Show-WfDialog -Title "Undo run $($a.RunId): current $($script:WfArrow) restored" -Lines $lines -PrimaryText "Restore $($r.Restorable)" -SecondaryText 'Back' `
            -PrimaryEnabled ($elev -and $r.Restorable -gt 0) -Data $a.RunId -OnPrimary {
                param($rid)
                Start-WfJob -Name 'undo' -Blocking -JobArgs @{ RunId = $rid } -Script { Invoke-WinForgeUndo -Context $Context -RunId $JobArgs.RunId 6>$null } -OnDone {
                    param($res)
                    Update-WfHistory; Update-WfStatus
                    Show-WfMessage -Title 'Undo result' -Lines @($res | ForEach-Object { "{0,-40} {1,-18} {2}" -f $_.Id, $_.Status, $_.Reason })
                } | Out-Null
            }
    } | Out-Null
}

function Update-WfMonitor {
    param([switch] $Save)
    $c = $script:wf.C
    $resolve = [bool]$c.MonitorResolve.IsChecked
    $out = $null
    if ($Save) {
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'JSON (*.json)|*.json'; $dlg.FileName = "connections-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json"
        if (-not $dlg.ShowDialog($script:wf.Window)) { return }
        $out = $dlg.FileName
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }   # the dialog already confirmed overwriting
    }
    $c.MonitorStatus.Text = if ($resolve) { 'Reading connections and looking up host names...' } else { 'Reading connections...' }
    Start-WfJob -Name 'monitor' -JobArgs @{ Resolve = $resolve; Out = $out } -Script {
        if ($JobArgs.Out) { Export-WinForgeConnectionSnapshot -Context $Context -OutFile $JobArgs.Out -ResolveNames:$JobArgs.Resolve | Out-Null }
        @(Get-WinForgeConnectionSnapshot -ResolveNames:$JobArgs.Resolve -EstablishedOnly)
    } -OnDone {
        param($r, $sync, $a)
        $c = $script:wf.C
        $c.MonitorGrid.ItemsSource = (ConvertTo-WfDataTable -Rows @($r) -Columns @('Process','PID','RemoteAddress','RemotePort','RemoteHost','Class')).DefaultView
        $by = @($r) | Group-Object Class | ForEach-Object { "$($_.Name): $($_.Count)" }
        $c.MonitorStatus.Text = "$(@($r).Count) established connections at $((Get-Date).ToString('HH:mm:ss')) $($script:WfDot) $($by -join ', ')$(if ($a.Out) { " $($script:WfDot) saved to $($a.Out)" })"
    } | Out-Null
}

# ---------------------------------------------------------------- startup

function Show-WinForgeWpf {
    param($Context)

    $xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'WinForge.xaml') -Raw -Encoding UTF8
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $controls = @{}
    foreach ($m in [regex]::Matches($xaml, 'x:Name="(\w+)"')) { $controls[$m.Groups[1].Value] = $window.FindName($m.Groups[1].Value) }

    $catalog = Get-WinForgeCatalog -Context $Context
    $script:wf = @{
        Context = $Context; Window = $window; C = $controls
        Sys = Get-WinForgeSystemInfo; Catalog = $catalog
        Profiles = @((Read-WinForgeJson (Join-Path $Context.CatalogRoot 'profiles.json')).profiles)
        Bundles = @((Read-WinForgeJson (Join-Path $Context.CatalogRoot 'bundles.json')).bundles)
        Apps = @((Get-WinForgeAppCatalog -Context $Context).apps)
        Status = @{}; Selected = New-Object 'System.Collections.Generic.HashSet[string]'
        Expert = $false; Jobs = New-Object System.Collections.ArrayList; BusyJob = $null; ApplyJob = $null
        History = @(); DialogAction = $null; DialogData = $null; DetailId = $null; DialogConfirmId = $null; DialogPrimaryAllowed = $true
        InstallButtons = New-Object System.Collections.ArrayList; AppTags = @{}
        PostureLoaded = $false; StatusLoaded = $false
    }
    $c = $controls

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({ Invoke-WfUi 'Background job' { Update-WfJobs } })
    $script:wf.Timer = $timer

    $window.Dispatcher.Add_UnhandledException({
        param($s, $e)
        Write-WinForgeLog -Level Error -Message "GUI unhandled: $($e.Exception.Message)"
        $e.Handled = $true
        [void][Windows.MessageBox]::Show($e.Exception.Message, 'WinForge error')
    })

    # Navigation
    foreach ($p in $script:WfPages.Keys) {
        $c["Nav$p"].Add_Checked({ $page = [string]$this.Tag; Invoke-WfUi 'Navigate' { Show-WfPage $page } })
    }

    # Filters and search
    [void]$c.FilterCategory.Items.Add('All categories')
    foreach ($cat in @($catalog.tweaks | ForEach-Object Category | Sort-Object -Unique)) { [void]$c.FilterCategory.Items.Add($cat) }
    $c.FilterCategory.SelectedIndex = 0
    foreach ($r in 'All risks','Safe','Caution') { [void]$c.FilterRisk.Items.Add($r) }
    $c.FilterRisk.SelectedIndex = 0
    $c.FilterCategory.Add_SelectionChanged({ Invoke-WfUi 'Filter' { Update-WfTweakList } })
    $c.FilterRisk.Add_SelectionChanged({ Invoke-WfUi 'Filter' { Update-WfTweakList } })
    $c.FilterNotApplied.Add_Click({ Invoke-WfUi 'Filter' { Update-WfTweakList } })
    $c.FilterSelected.Add_Click({ Invoke-WfUi 'Filter' { Update-WfTweakList } })
    $c.SearchBox.Add_TextChanged({ Invoke-WfUi 'Search' {
        $script:wf.C.SearchHint.Visibility = if ($script:wf.C.SearchBox.Text) { 'Collapsed' } else { 'Visible' }
        if ($script:wf.C.SearchBox.Text -and $script:wf.C.PageTweaks.Visibility -ne 'Visible') { Show-WfPage 'Tweaks' }
        Update-WfTweakList
    } })
    $c.SelectShownBtn.Add_Click({ Invoke-WfUi 'Select' {
        foreach ($row in $script:wf.C.TweakList.Children) {
            $t = $script:wf.Catalog.tweaks | Where-Object Id -eq $row.Tag
            if ($t -and $t.Risk -ne 'Danger' -and -not (([string]$script:wf.Status[$t.Id]) -like 'unsupported*')) { [void]$script:wf.Selected.Add($t.Id) }
        }
        Update-WfSelectionLine; Update-WfTweakList; Update-WfEssentials
    } })
    $c.RefreshStatusBtn.Add_Click({ Invoke-WfUi 'Status' { Update-WfStatus } })

    # Footer and hero
    $c.ReviewBtn.Add_Click({ Invoke-WfUi 'Review' { Show-WfReview } })
    $c.HeroPreviewBtn.Add_Click({ Invoke-WfUi 'Review' { Show-WfReview } })
    $c.ExploreBtn.Add_Click({ Invoke-WfUi 'Navigate' { Show-WfPage 'Tweaks' } })
    $c.ClearSelectionBtn.Add_Click({ Invoke-WfUi 'Clear' { $script:wf.Selected.Clear(); Update-WfSelectionLine; Update-WfTweakList; Update-WfEssentials } })
    $c.CancelRunBtn.Add_Click({ Invoke-WfUi 'Cancel' {
        if ($script:wf.BusyJob) { $script:wf.BusyJob.Sync.Cancelled = $true; $script:wf.C.CancelRunBtn.IsEnabled = $false; $script:wf.C.SelectionLine.Text = 'Cancelling after the current tweak...' }
    } })
    $c.DashHistoryLink.Add_Click({ Invoke-WfUi 'Navigate' { Show-WfPage 'History' } })

    # Pages
    $c.SecurityRefreshBtn.Add_Click({ Invoke-WfUi 'Security' { Update-WfSecurity } })
    $c.MonitorRefreshBtn.Add_Click({ Invoke-WfUi 'Monitor' { Update-WfMonitor } })
    $c.MonitorExportBtn.Add_Click({ Invoke-WfUi 'Monitor' { Update-WfMonitor -Save } })
    $c.HistoryRefreshBtn.Add_Click({ Invoke-WfUi 'History' { Update-WfHistory } })
    $c.RunsGrid.Add_SelectionChanged({ Invoke-WfUi 'History' { Show-WfRunDetail } })
    $c.UndoRunBtn.Add_Click({ Invoke-WfUi 'Undo' { Start-WfUndo } })
    $c.ExpertToggle.Add_Click({ Invoke-WfUi 'Expert mode' {
        $on = [bool]$script:wf.C.ExpertToggle.IsChecked
        $script:wf.Expert = $on
        if (-not $on) { foreach ($t in @($script:wf.Catalog.tweaks | Where-Object Risk -eq 'Danger')) { [void]$script:wf.Selected.Remove($t.Id) } }
        $script:wf.C.ModeText.Text = if ($on) { 'Expert mode' } else { 'Standard mode' }
        $script:wf.C.ModePill.Background = ConvertTo-WfBrush $(if ($on) { '#F3CFC2' } else { '#E0E9D7' })
        $fr = $script:wf.C.FilterRisk
        if ($on -and -not $fr.Items.Contains('Danger')) { [void]$fr.Items.Add('Danger') }
        if (-not $on -and $fr.Items.Contains('Danger')) { if ([string]$fr.SelectedItem -eq 'Danger') { $fr.SelectedIndex = 0 }; $fr.Items.Remove('Danger') }
        Update-WfSelectionLine; Update-WfTweakList
    } })
    $c.ValidateBtn.Add_Click({ Invoke-WfUi 'Validate' {
        $r = Test-WinForgeCatalog -Context $script:wf.Context
        $script:wf.C.ValidateResult.Text = if ($r.Valid) { 'Catalog OK: every tweak, profile, app and bundle passed validation.' } else { ($r.Errors -join "`n") }
    } })

    # Dialog
    $c.DialogClose.Add_Click({ Invoke-WfUi 'Dialog' { Close-WfDialog } })
    $c.DialogSecondary.Add_Click({ Invoke-WfUi 'Dialog' { Close-WfDialog } })
    $c.DialogPrimary.Add_Click({ Invoke-WfUi 'Dialog' {
        $action = $script:wf.DialogAction; $data = $script:wf.DialogData
        Close-WfDialog
        if ($action) { & $action $data }
    } })
    $c.ExpertConfirmBox.Add_TextChanged({ Invoke-WfUi 'Confirm' {
        $script:wf.C.DialogPrimary.IsEnabled = $script:wf.DialogPrimaryAllowed -and ($script:wf.C.ExpertConfirmBox.Text -ceq $script:wf.DialogConfirmId)
    } })
    $c.Overlay.Add_MouseLeftButtonDown({ if ($args[1].OriginalSource -eq $script:wf.C.Overlay) { Invoke-WfUi 'Dialog' { Close-WfDialog } } })
    $window.Add_PreviewKeyDown({
        if ($args[1].Key -eq 'Escape' -and $script:wf.C.Overlay.Visibility -eq 'Visible') { $args[1].Handled = $true; Invoke-WfUi 'Dialog' { Close-WfDialog } }
    })
    # The sidebar's footer card only fits on taller windows; hide it rather than clip it.
    $window.Add_SizeChanged({ $script:wf.C.SideFoot.Visibility = if ($script:wf.Window.ActualHeight -lt 860) { 'Collapsed' } else { 'Visible' } })
    $window.Add_Closing({
        if ($script:wf.BusyJob) {
            $args[1].Cancel = $true
            Show-WfMessage -Title 'A run is in progress' -Lines @("Wait for '$($script:wf.BusyJob.Name)' to finish (or press Cancel run) before closing.")
        }
    })

    # Initial data
    Update-WfDashboardStatic
    Update-WfSelectionLine
    Update-WfEssentials
    Update-WfTweakList
    Update-WfBundles
    Update-WfHistory
    Update-WfStatus
    Update-WfSecurity

    # Test hook: render the window (optionally a given page) to a PNG and close.
    if ($env:WINFORGE_UI_SNAPSHOT) {
        $window.Add_ContentRendered({
            $snap = New-Object Windows.Threading.DispatcherTimer
            $snap.Interval = [TimeSpan]::FromMilliseconds(500)
            $script:wfSnapStart = Get-Date
            $snap.Add_Tick({
                if ((@($script:wf.Jobs).Count -gt 0) -and ((Get-Date) - $script:wfSnapStart).TotalSeconds -lt 40) { return }
                $this.Stop()
                if ($env:WINFORGE_UI_PAGE) { Show-WfPage $env:WINFORGE_UI_PAGE }
                if ($env:WINFORGE_UI_DIALOG -eq 'review') { foreach ($id in @(($script:wf.Profiles | Where-Object Id -eq 'Recommended').TweakIds)) { [void]$script:wf.Selected.Add($id) }; Show-WfReview }
                $shot = New-Object Windows.Threading.DispatcherTimer
                $shot.Interval = [TimeSpan]::FromMilliseconds(1500)
                $shot.Add_Tick({
                    if ((@($script:wf.Jobs).Count -gt 0) -and ((Get-Date) - $script:wfSnapStart).TotalSeconds -lt 60) { return }
                    $this.Stop()
                    $w = $script:wf.Window
                    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$w.ActualWidth, [int]$w.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                    $bmp.Render($w.Content)
                    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
                    $fs = [IO.File]::Create($env:WINFORGE_UI_SNAPSHOT); $enc.Save($fs); $fs.Close()
                    $w.Close()
                })
                $shot.Start()
            })
            $snap.Start()
        })
    }

    [void]$window.ShowDialog()
    $timer.Stop()
    foreach ($job in @($script:wf.Jobs)) { $job.Sync.Cancelled = $true; Stop-WinForgeJobRunspace -Job $job }
}
