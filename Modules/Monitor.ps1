# Host classification ported from PrivGuard. It is a best-effort match on the PTR name
# the address owner published: absent or generic PTR records stay Unresolved/Other, and a
# match is not proof of ownership. This is not packet capture; it shows who a process is
# connected to, not what is sent.
$script:WinForgeTelemetryHosts = @(
    'v10.events.data.microsoft.com','v20.events.data.microsoft.com','watson.telemetry.microsoft.com',
    'settings-win.data.microsoft.com','self.events.data.microsoft.com'
)
$script:WinForgeHostSuffixes = [ordered]@{
    Security = @('wd.microsoft.com','smartscreen.microsoft.com','wdcp.microsoft.com','wdcpalt.microsoft.com')
    Update   = @('windowsupdate.com','delivery.mp.microsoft.com','do.dsp.mp.microsoft.com')
    General  = @('microsoft.com','azure.com','azureedge.net','msedge.net','windows.com','office.com',
                 'office365.com','live.com','bing.com','msftncsi.com','msn.com','trafficmanager.net')
}

function Get-WinForgeConnectionClass {
    param([string] $Hostname)
    if ([string]::IsNullOrWhiteSpace($Hostname)) { return 'Unresolved' }
    $h = $Hostname.ToLower().TrimEnd('.')
    if ($script:WinForgeTelemetryHosts -contains $h) { return 'Telemetry' }
    foreach ($class in $script:WinForgeHostSuffixes.Keys) {
        foreach ($s in $script:WinForgeHostSuffixes[$class]) { if ($h -eq $s -or $h.EndsWith(".$s")) { return $class } }
    }
    return 'Other'
}

function Resolve-WinForgePtr {
    param([string] $Address, [hashtable] $Cache)
    if ($Cache.ContainsKey($Address)) { return $Cache[$Address] }
    $name = $null
    try {
        $r = Resolve-DnsName -Name $Address -Type PTR -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.PSObject.Properties['NameHost'] } | Select-Object -First 1
        if ($r) { $name = $r.NameHost.TrimEnd('.') }
    } catch { $name = $null }
    $Cache[$Address] = $name
    return $name
}

function Get-WinForgeConnectionSnapshot {
    # -ResolveNames performs a reverse DNS lookup per remote address (network traffic),
    # so it is opt-in. Without it, Class says why it is unknown instead of guessing.
    param([switch] $ResolveNames, [switch] $EstablishedOnly)
    $conns = Get-NetTCPConnection -ErrorAction SilentlyContinue
    if ($EstablishedOnly) { $conns = $conns | Where-Object { $_.State -eq 'Established' } }
    $dns = @{}; $procs = @{}
    foreach ($c in $conns) {
        $procId = $c.OwningProcess
        if (-not $procs.ContainsKey($procId)) {
            $procs[$procId] = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { 'unknown' }
        }
        $remote = [string]$c.RemoteAddress
        $isRemote = $c.State -eq 'Established' -and $remote -notin @('0.0.0.0','::','127.0.0.1','::1')
        $hostname = $null
        $class = if (-not $isRemote) { 'Local' } elseif (-not $ResolveNames) { 'Unclassified (run with -ResolveNames)' } else {
            $hostname = Resolve-WinForgePtr -Address $remote -Cache $dns
            Get-WinForgeConnectionClass -Hostname $hostname
        }
        [pscustomobject]@{
            LocalAddress = $c.LocalAddress; LocalPort = $c.LocalPort
            RemoteAddress = $remote; RemotePort = $c.RemotePort; RemoteHost = $hostname
            State = [string]$c.State; Process = $procs[$procId]; PID = $procId; Class = $class
        }
    }
}

function Export-WinForgeConnectionSnapshot {
    param($Context, [string] $OutFile, [switch] $ResolveNames)
    if (-not $OutFile) {
        $dir = if ($Context.StateWritable) { Join-Path $Context.StateRoot 'snapshots' } else { Join-Path $env:LOCALAPPDATA 'WinForge\snapshots' }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $OutFile = Join-Path $dir ("connections-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
    }
    if (Test-Path -LiteralPath $OutFile) { throw "Refusing to overwrite existing file: $OutFile" }
    $snap = @(Get-WinForgeConnectionSnapshot -ResolveNames:$ResolveNames -EstablishedOnly)
    ConvertTo-Json -InputObject $snap -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    return $OutFile
}

function Compare-WinForgeConnectionSnapshots {
    # Compares by remote endpoint and process. Ephemeral local ports are ignored, so a
    # reconnect to the same endpoint is not reported as a change.
    param([string] $Before, [string] $After)
    # Windows PowerShell's ConvertFrom-Json emits a JSON array as one object; the extra
    # pipeline stage enumerates it into its elements.
    $b = @((Get-Content -LiteralPath $Before -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
    $a = @((Get-Content -LiteralPath $After  -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
    $key = { param($x) "$($x.Process) -> $($x.RemoteAddress):$($x.RemotePort)" }
    $bSet = @{}; $aSet = @{}
    foreach ($x in $b) { $bSet[(& $key $x)] = $x }
    foreach ($x in $a) { $aSet[(& $key $x)] = $x }
    $rows = @()
    foreach ($k in $bSet.Keys) { if (-not $aSet.ContainsKey($k)) { $rows += [pscustomobject]@{ Change = 'Gone'; Connection = $k; Class = $bSet[$k].Class } } }
    foreach ($k in $aSet.Keys) {
        $rows += [pscustomobject]@{ Change = $(if ($bSet.ContainsKey($k)) { 'Remains' } else { 'New' }); Connection = $k; Class = $aSet[$k].Class }
    }
    return $rows | Sort-Object Change, Connection
}
