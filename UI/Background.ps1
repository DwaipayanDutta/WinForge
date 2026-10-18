# Background jobs for the WPF front end. Every slow or system-changing engine call runs
# in its own runspace so the window never freezes. A job gets the engine loaded, its
# arguments, and a synchronized table ($sync) it reports through: Progress, Total,
# Cancelled (set by the UI), Done, Result and Error. The UI polls with a DispatcherTimer
# and runs the job's completion callback on the UI thread.

$script:WinForgeEngineFiles = @(
    'Core\Context.ps1','Core\Logging.ps1','Core\Catalog.ps1','Core\Compatibility.ps1',
    'Core\State.ps1','Core\Planner.ps1','Core\Authorization.ps1','Core\History.ps1',
    'Adapters\Registry.ps1','Adapters\Service.ps1','Adapters\Task.ps1','Adapters\Feature.ps1','Adapters\Appx.ps1',
    'Core\Engine.ps1','Modules\Dashboard.ps1','Modules\Debloat.ps1','Modules\Privacy.ps1',
    'Modules\Monitor.ps1','Modules\SecurityAudit.ps1','Modules\Installer.ps1'
)

function Start-WinForgeJob {
    param(
        $Context,
        [string] $Name,
        # Runs inside the job runspace with $Context, $JobArgs and $sync defined. Passed as
        # text so the scriptblock is not bound to the UI runspace.
        [scriptblock] $Script,
        [hashtable] $JobArgs = @{},
        [int] $Total = 1
    )
    $sync = [hashtable]::Synchronized(@{ Name = $Name; Progress = 0; Total = $Total; Cancelled = $false; Done = $false; Result = $null; Error = $null })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('Context', $Context)
    $rs.SessionStateProxy.SetVariable('JobArgs', $JobArgs)
    $rs.SessionStateProxy.SetVariable('WinForgeEngineFiles', $script:WinForgeEngineFiles)

    $loader = {
        param($root, $body)
        try {
            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'
            foreach ($f in $WinForgeEngineFiles) { . (Join-Path $root $f) }
            Initialize-WinForgeLog -Context $Context
            $sync.Result = & ([scriptblock]::Create($body))
        } catch {
            $sync.Error = $_.Exception.Message
        } finally {
            $sync.Done = $true
        }
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($loader.ToString()).AddArgument($Context.Root).AddArgument($Script.ToString())
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ Name = $Name; PS = $ps; Handle = $handle; Sync = $sync }
}

function Stop-WinForgeJobRunspace {
    param($Job)
    try { $Job.PS.EndInvoke($Job.Handle) | Out-Null } catch { Write-Verbose "Job $($Job.Name): $($_.Exception.Message)" }
    try { $Job.PS.Runspace.Close(); $Job.PS.Dispose() } catch { Write-Verbose "Job $($Job.Name) dispose: $($_.Exception.Message)" }
}
