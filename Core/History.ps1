$script:RunIdPattern = '^\d{8}T\d{6}Z-[0-9a-f]{6}$'

function New-WinForgeRunId {
    return ('{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0,6)))
}

function Save-RunRecord {
    param($Context, $Record)
    $path = Join-Path $Context.RunDir ("{0}.json" -f $Record.RunId)
    # Write to a temp file and move, so an interrupted run never leaves a half-written record.
    $tmp = "$path.tmp"
    $Record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Get-RunRecord {
    param($Context, [string] $RunId)
    if ($RunId -notmatch $script:RunIdPattern) { throw "Invalid run ID '$RunId'." }
    $path = Join-Path $Context.RunDir ("{0}.json" -f $RunId)
    if (-not (Test-Path -LiteralPath $path)) { throw "Run '$RunId' not found." }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-WinForgeHistory {
    param($Context)
    $out = @()
    foreach ($f in Get-ChildItem -LiteralPath $Context.RunDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $tw = @($r.Tweaks)
        $out += [pscustomobject]@{
            RunId = $r.RunId; StartedUtc = $r.StartedUtc; Profile = $r.Profile; State = $r.State
            Applied  = @($tw | Where-Object { $_.Status -in @('AppliedVerified','AwaitingRestart') }).Count
            Failed   = @($tw | Where-Object { $_.Status -in @('Failed','Partial','VerifyFailed','RolledBack') }).Count
            Restored = @($tw | Where-Object { $_.Status -eq 'Restored' -or ($_.PSObject.Properties['UndoStatus'] -and $_.UndoStatus -eq 'Restored') }).Count
        }
    }
    return $out | Sort-Object StartedUtc -Descending
}
