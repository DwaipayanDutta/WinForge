if (-not (Get-Variable -Name LogPath -Scope Script -ErrorAction SilentlyContinue)) { $script:LogPath = $null }

function Initialize-WinForgeLog {
    param($Context)
    $script:LogPath = if ($Context.PSObject.Properties['StateWritable'] -and -not $Context.StateWritable) { $null }
                      else { Join-Path $Context.LogDir ("winforge-{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
}

function Write-WinForgeLog {
    param(
        [ValidateSet('Debug','Info','Warn','Error')] [string] $Level = 'Info',
        [string] $Message,
        [string] $LogPath = $script:LogPath
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'o'), $Level, $Message
    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $line -ErrorAction SilentlyContinue }
    if ($Level -eq 'Error') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'Warn') { Write-Host $line -ForegroundColor Yellow }
    else { Write-Host $line }
}
