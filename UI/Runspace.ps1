function New-WinForgeApplyRunspace {
    param($Context, [string[]] $TweakId, [Alias('Profile')] [string] $ProfileName, [switch] $Expert, [string] $TypedConfirmation)

    $sync = [hashtable]::Synchronized(@{
        Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Progress = 0; Total = $TweakId.Count; Done = $false
        Result = $null; Error = $null; Cancelled = $false
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('Context', $Context)
    $rs.SessionStateProxy.SetVariable('TweakId', $TweakId)
    $rs.SessionStateProxy.SetVariable('ProfileName', $ProfileName)
    $rs.SessionStateProxy.SetVariable('Expert', [bool]$Expert)
    $rs.SessionStateProxy.SetVariable('TypedConfirmation', $TypedConfirmation)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($root)
        try {
            foreach ($f in @('Core\Context.ps1','Core\Logging.ps1','Core\Catalog.ps1','Core\Compatibility.ps1','Core\State.ps1','Core\Planner.ps1','Core\Authorization.ps1','Core\History.ps1','Adapters\Registry.ps1','Adapters\Service.ps1','Adapters\Task.ps1','Adapters\Feature.ps1','Adapters\Appx.ps1','Core\Engine.ps1')) {
                . (Join-Path $root $f)
            }
            Initialize-WinForgeLog -Context $Context
            $sync.Log.Add('Starting apply...') | Out-Null
            # The GUI showed the plan and the user clicked Yes before this runspace started.
            $r = Invoke-WinForgeOperation -Context $Context -TweakId $TweakId -Profile $ProfileName -Expert:$Expert -TypedConfirmation $TypedConfirmation -Force
            $sync.Progress = $sync.Total
            $sync.Result = $r
        } catch {
            $sync.Error = $_.Exception.Message
        } finally {
            $sync.Done = $true
        }
    }).AddArgument($Context.Root)

    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ PS = $ps; Handle = $handle; Sync = $sync }
}