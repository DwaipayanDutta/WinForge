function Get-WinForgeProviders {
    $p = [pscustomobject]@{ winget = $null; choco = $null }
    try { $p.winget = (& winget --version 2>$null) } catch { Write-Verbose 'winget not found' }
    try { $p.choco  = (& choco  --version 2>$null) } catch { Write-Verbose 'choco not found' }
    return $p
}

function Get-WinForgeAppCatalog {
    param($Context)
    $p = Join-Path $Context.CatalogRoot 'apps.json'
    if (-not (Test-Path -LiteralPath $p)) { throw "App catalog not found: $p" }
    return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-WinForgeBundle {
    param($Context, [string] $Id)
    $p = Join-Path $Context.CatalogRoot 'bundles.json'
    $doc = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    return $doc.bundles | Where-Object { $_.Id -eq $Id }
}

function Get-WinForgeInstallArguments {
    # Package IDs are validated by Test-WinForgeAppCatalog and passed as discrete
    # arguments, never through a shell string. --source pins winget to its community
    # repository so an ID cannot resolve to an unexpected msstore package.
    param([string] $Provider, [string] $PackageId)
    if ($Provider -eq 'winget') {
        return @('install','--id',$PackageId,'--exact','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements')
    }
    return @('install',$PackageId,'-y','--no-progress')
}

function Test-WinForgeAppInstalled {
    param($App, [string] $Provider)
    $id = $App.Providers.$Provider
    if (-not $id) { return $false }
    if ($Provider -eq 'winget') {
        $out = & winget list --id $id --exact --accept-source-agreements 2>$null
        return ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match [regex]::Escape($id))
    }
    if ($Provider -eq 'choco') {
        # Chocolatey 2.x removed --local-only ('list' is local by default); 1.x needs it.
        $major = 0
        try { $major = ([version]((& choco --version 2>$null) -replace '[^0-9.].*$', '')).Major } catch { $major = 0 }
        $listArgs = if ($major -ge 2) { @('list','--exact',$id,'--limit-output') } else { @('list','--local-only','--exact',$id,'--limit-output') }
        $out = & choco @listArgs 2>$null
        return ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match ('(?im)^' + [regex]::Escape($id) + '\|'))
    }
    return $false
}

function Install-WinForgeApp {
    param($App, [ValidateSet('winget','choco')] [string] $Provider = 'winget', [switch] $DryRun)

    $id = $App.Providers.$Provider
    if (-not $id) { throw "App '$($App.Id)' has no $Provider ID." }
    if (Test-WinForgeAppInstalled -App $App -Provider $Provider) {
        return [pscustomobject]@{ Id = $App.Id; Status = 'AlreadyInstalled'; Provider = $Provider; Reason = '' }
    }
    if ($DryRun) { return [pscustomobject]@{ Id = $App.Id; Status = 'WouldInstall'; Provider = $Provider; Package = $id; Reason = '' } }

    $installArgs = Get-WinForgeInstallArguments -Provider $Provider -PackageId $id
    $exe = if ($Provider -eq 'winget') { 'winget' } else { 'choco' }
    Write-WinForgeLog -Message "Installing $($App.Name) via $Provider ($id)"
    & $exe @installArgs
    $rc = $LASTEXITCODE

    if ($rc -ne 0) { return [pscustomobject]@{ Id = $App.Id; Status = 'Failed'; Provider = $Provider; ExitCode = $rc; Reason = "$exe exited with $rc" } }
    $ok = Test-WinForgeAppInstalled -App $App -Provider $Provider
    return [pscustomobject]@{
        Id = $App.Id; Status = if ($ok) { 'InstalledVerified' } else { 'InstalledUnverified' }
        Provider = $Provider; ExitCode = $rc; Reason = if ($ok) { '' } else { 'Provider reported success but the app was not found afterwards' }
    }
}

function Install-WinForgeBundle {
    param($Context, [string] $BundleId, [switch] $DryRun, [switch] $AllowChocoFallback, [switch] $NoRestorePoint)

    Assert-WinForgeCatalog -Context $Context
    $providers = Get-WinForgeProviders
    $catalog = Get-WinForgeAppCatalog -Context $Context
    $bundle  = Get-WinForgeBundle -Context $Context -Id $BundleId
    if (-not $bundle) { throw "Bundle '$BundleId' not found." }

    $apps = $catalog.apps | Where-Object { $bundle.Apps -contains $_.Id }
    $record = [pscustomobject]@{
        InstallId = New-WinForgeRunId; StartedUtc = [DateTime]::UtcNow.ToString('o'); FinishedUtc = $null
        Bundle = $BundleId; DryRun = [bool]$DryRun; ChocoFallback = [bool]$AllowChocoFallback
        Providers = $providers; RestorePoint = $null; Results = @()
    }

    # Installers run arbitrary vendor code, so take a System Restore point first. Best
    # effort: System Restore is often off, and Windows allows one point per 24 hours.
    if (-not $DryRun -and -not $NoRestorePoint) {
        if (-not $Context.Elevated) { $record.RestorePoint = 'Skipped: requires elevation' }
        else {
            try {
                Checkpoint-Computer -Description "WinForge: install bundle $BundleId" -RestorePointType APPLICATION_INSTALL -ErrorAction Stop -WarningAction SilentlyContinue
                $record.RestorePoint = 'Created'
            } catch { $record.RestorePoint = "Not created: $($_.Exception.Message)" }
        }
        Write-WinForgeLog -Level $(if ($record.RestorePoint -eq 'Created') { 'Info' } else { 'Warn' }) -Message "Restore point: $($record.RestorePoint)"
    }

    $report = @()
    foreach ($a in $apps) {
        $provider = if ($providers.winget -and $a.Providers.winget) { 'winget' } elseif ($providers.choco -and $a.Providers.choco) { 'choco' } else { $null }
        if (-not $provider) { $report += [pscustomobject]@{ Id = $a.Id; Status = 'NoProvider'; Reason = 'No installed provider offers this app' }; continue }
        try { $r = Install-WinForgeApp -App $a -Provider $provider -DryRun:$DryRun }
        catch { $r = [pscustomobject]@{ Id = $a.Id; Status = 'Failed'; Provider = $provider; Reason = $_.Exception.Message } }

        # Fall back on a reported failure as well as an exception: winget signals most
        # failures through its exit code, not by throwing.
        if ($r.Status -eq 'Failed' -and $AllowChocoFallback -and $provider -eq 'winget' -and $providers.choco -and $a.Providers.choco) {
            try { $r = Install-WinForgeApp -App $a -Provider 'choco' -DryRun:$DryRun }
            catch { $r = [pscustomobject]@{ Id = $a.Id; Status = 'Failed'; Provider = 'choco'; Reason = $_.Exception.Message } }
        }
        $report += $r
    }

    $record.Results = $report; $record.FinishedUtc = [DateTime]::UtcNow.ToString('o')
    $dir = Get-WinForgeInstallDir -Context $Context
    if (-not $DryRun -and $dir) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir "$($record.InstallId).json") -Encoding UTF8
    }
    return $report
}

function Get-WinForgeInstallDir {
    param($Context)
    if ($Context.StateWritable) { return (Join-Path $Context.StateRoot 'installs') }
    return (Join-Path $env:LOCALAPPDATA 'WinForge\installs')
}

function Get-WinForgeInstallHistory {
    param($Context)
    $dir = Get-WinForgeInstallDir -Context $Context
    $out = @()
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue) {
        $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $res = @($r.Results)
        $out += [pscustomobject]@{
            InstallId = $r.InstallId; StartedUtc = $r.StartedUtc; Bundle = $r.Bundle; RestorePoint = $r.RestorePoint
            Installed = @($res | Where-Object { $_.Status -eq 'InstalledVerified' }).Count
            Failed    = @($res | Where-Object { $_.Status -in @('Failed','InstalledUnverified','NoProvider') }).Count
        }
    }
    return $out | Sort-Object StartedUtc -Descending
}
