$script:WinForgeRepo = 'DwaipayanDutta/WinForge'

function Enable-WinForgeTls12 {
    # Windows PowerShell 5.1 may default to TLS 1.0/1.1, which GitHub rejects.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Test-WinForgeReleaseUrl {
    param([string] $Url, [string] $Repo = $script:WinForgeRepo)
    return ($Url -match ('^https://github\.com/' + [regex]::Escape($Repo) + '/releases/download/[^/?#]+/[^/?#]+$'))
}

function Get-WinForgeLatestRelease {
    param([string] $Repo = $script:WinForgeRepo)
    Enable-WinForgeTls12
    $uri = "https://api.github.com/repos/$Repo/releases/latest"
    $r = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'WinForge' } -ErrorAction Stop
    return [pscustomobject]@{
        Tag = $r.tag_name; Name = $r.name; Published = $r.published_at
        Assets = $r.assets | ForEach-Object { [pscustomobject]@{ Name = $_.name; Url = $_.browser_download_url; Size = $_.size } }
    }
}

function Test-WinForgeHash {
    param([string] $File, [string] $ExpectedHash)
    if (-not (Test-Path -LiteralPath $File)) { throw "File not found: $File" }
    if ($ExpectedHash -notmatch '^[0-9A-Fa-f]{64}$') { throw "Expected hash is not a SHA256 value: '$ExpectedHash'" }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    return [pscustomobject]@{ Match = ($actual -eq $ExpectedHash.ToUpper()); Actual = $actual }
}

function Get-WinForgeExpectedHash {
    # Parses "<sha256>  <file>" (optionally "*<file>") and matches the file name exactly,
    # so 'WinForge-1.0.zip' never matches a line for 'WinForge-1.0.zip.old'.
    param([string[]] $SumsLines, [string] $FileName)
    foreach ($l in $SumsLines) {
        if ($l -match '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $FileName) { return $Matches[1] }
    }
    throw "SHA256SUMS.txt does not list '$FileName'."
}

function Invoke-WinForgeUpdateCheck {
    param($Context, [switch] $Download, [string] $OutDir)

    $rel = Get-WinForgeLatestRelease
    Write-WinForgeLog -Message "Latest release: $($rel.Tag) ($($rel.Published))"
    $zip = $rel.Assets | Where-Object { $_.Name -like 'WinForge-*.zip' } | Select-Object -First 1
    $sums = $rel.Assets | Where-Object { $_.Name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $zip -or -not $sums) { throw 'Release is missing the zip or SHA256SUMS.txt.' }
    foreach ($a in $zip, $sums) { if (-not (Test-WinForgeReleaseUrl $a.Url)) { throw "Refusing asset URL outside the WinForge GitHub releases: $($a.Url)" } }

    $latest = $null; $current = $null
    try { $latest = [version]($rel.Tag -replace '^v', ''); $current = [version]$Context.Version } catch { Write-Verbose 'Version not comparable' }
    $newer = if ($latest -and $current) { $latest -gt $current } else { $null }

    if (-not $Download) {
        return [pscustomobject]@{ Current = $Context.Version; Latest = $rel.Tag; UpdateAvailable = $newer; Zip = $zip.Name; Verified = $false }
    }

    if (-not $OutDir) {
        # A non-elevated process cannot write the protected %ProgramData% state folder;
        # downloads are inert files, so they go to the user's own profile instead.
        $OutDir = if ($Context.StateWritable) { Join-Path $Context.StateRoot 'updates' } else { Join-Path $env:LOCALAPPDATA 'WinForge\updates' }
    }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $zipPath = Join-Path $OutDir $zip.Name
    $sumPath = Join-Path $OutDir $sums.Name
    Invoke-WebRequest -Uri $zip.Url -OutFile $zipPath -UseBasicParsing
    Invoke-WebRequest -Uri $sums.Url -OutFile $sumPath -UseBasicParsing

    $expected = Get-WinForgeExpectedHash -SumsLines (Get-Content -LiteralPath $sumPath) -FileName $zip.Name
    $v = Test-WinForgeHash -File $zipPath -ExpectedHash $expected
    if (-not $v.Match) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "Hash mismatch for $($zip.Name). Expected $expected, got $($v.Actual). The download was deleted."
    }

    # The hash proves the zip matches what the release published. It does not prove who
    # published it; that needs code signing (Phase 7). Nothing is extracted or run here.
    Write-WinForgeLog -Message "Verified $($zip.Name) (SHA256 $($v.Actual)). Not applied; extract it yourself after review."
    return [pscustomobject]@{ Current = $Context.Version; Latest = $rel.Tag; UpdateAvailable = $newer; Zip = $zipPath; Verified = $true; Sha256 = $v.Actual }
}
