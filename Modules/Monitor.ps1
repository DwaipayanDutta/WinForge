function Get-WinForgeConnectionSnapshot {
    $conns = Get-NetTCPConnection -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        $proc = try { (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch { 'unknown' }
        [pscustomobject]@{
            LocalAddress = $c.LocalAddress; LocalPort = $c.LocalPort
            RemoteAddress = $c.RemoteAddress; RemotePort = $c.RemotePort
            State = $c.State; Process = $proc
            Class = 'Unclassified (no reverse DNS lookup performed)'
        }
    }
}

function Export-WinForgeConnectionSnapshot {
    param($Context)
    $dir = Join-Path $Context.StateRoot 'snapshots'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ("connections-{0}.json" -f (Get-Date -Format 'yyyyMMddTHHmmssZ'))
    Get-WinForgeConnectionSnapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Compare-WinForgeConnectionSnapshots {
    param([string] $Before, [string] $After)
    $b = Get-Content -LiteralPath $Before -Raw | ConvertFrom-Json
    $a = Get-Content -LiteralPath $After  -Raw | ConvertFrom-Json
    $key = { param($x) "$($x.RemoteAddress):$($x.RemotePort)/$($x.Process)" }
    $bSet = @{}; $aSet = @{}
    foreach ($x in $b) { $bSet[(& $key $x)] = $true }
    foreach ($x in $a) { $aSet[(& $key $x)] = $true }
    [pscustomobject]@{
        Removed = @($bSet.Keys | Where-Object { -not $aSet.ContainsKey($_) })
        Added   = @($aSet.Keys | Where-Object { -not $bSet.ContainsKey($_) })
    }
}