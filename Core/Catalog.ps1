function Get-WinForgeField {
    # Strict-mode-safe property read: catalog entries are untrusted and may omit fields.
    param($Object, [string] $Name)
    if ($null -eq $Object -or $Object -isnot [psobject]) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Read-WinForgeJson {
    param([string] $Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-WinForgeCatalog {
    param($Context)
    $tweaksPath = Join-Path $Context.CatalogRoot 'tweaks.json'
    if (-not (Test-Path -LiteralPath $tweaksPath)) { throw "Catalog not found: $tweaksPath" }
    return Read-WinForgeJson $tweaksPath
}

function Get-WinForgeTweak {
    param([string] $Id, $Context, $Catalog)
    if (-not $Catalog) { $Catalog = Get-WinForgeCatalog -Context $Context }
    foreach ($t in $Catalog.tweaks) { if ($t.Id -eq $Id) { return $t } }
    return $null
}

function Get-WinForgeProfile {
    param([string] $Name, $Context)
    $p = Join-Path $Context.CatalogRoot 'profiles.json'
    if (-not (Test-Path -LiteralPath $p)) { throw "Profiles not found: $p" }
    $doc = Read-WinForgeJson $p
    foreach ($prof in $doc.profiles) { if ($prof.Id -eq $Name) { return $prof } }
    throw "Profile '$Name' not found."
}

# Registry locations that launch code or weaken core protections. A catalog entry that
# writes here is rejected even if every other field is valid: a data-only catalog must
# not be able to plant persistence or code execution through the registry adapter.
$script:WinForgeDeniedRegistry = @(
    @{ Path = '^SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\(Run|RunOnce|RunOnceEx|RunServices|RunServicesOnce)(\\|$)' }
    @{ Path = '^SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer\\Run(\\|$)' }
    @{ Path = '^SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows NT\\CurrentVersion\\(Image File Execution Options|SilentProcessExit)(\\|$)' }
    @{ Path = '^SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows NT\\CurrentVersion\\Winlogon(\\|$)'; Names = '^(Shell|Userinit|Taskman|VmApplet|AppSetup|GinaDLL)$' }
    @{ Path = '^SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows NT\\CurrentVersion\\Windows(\\|$)'; Names = '^(AppInit_DLLs|LoadAppInit_DLLs|Load|Run)$' }
    @{ Path = '^SYSTEM\\(CurrentControlSet|ControlSet\d{3})\\Services\\'; Names = '^(ImagePath|ServiceDll|FailureCommand|ObjectName)$' }
    @{ Path = '^SYSTEM\\(CurrentControlSet|ControlSet\d{3})\\Control\\Session Manager(\\|$)'; Names = '^(BootExecute|SetupExecute|Execute|AppCertDlls|KnownDLLs)$' }
    @{ Path = '^SYSTEM\\(CurrentControlSet|ControlSet\d{3})\\Control\\Session Manager\\(AppCertDlls|KnownDLLs)(\\|$)' }
    @{ Path = '^SYSTEM\\(CurrentControlSet|ControlSet\d{3})\\Control\\Lsa(\\|$)'; Names = '^(Security Packages|Authentication Packages|Notification Packages|RunAsPPL|LmCompatibilityLevel)$' }
    @{ Path = '^SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Policies\\System(\\|$)'; Names = '^(EnableLUA|ConsentPromptBehaviorAdmin|PromptOnSecureDesktop|FilterAdministratorToken)$' }
    @{ Path = '^SOFTWARE\\(WOW6432Node\\)?Policies\\Microsoft\\Windows\\System\\Scripts(\\|$)' }
    @{ Path = '(^|\\)(InprocServer32|LocalServer32|InprocHandler32|TreatAs)(\\|$)' }
    @{ Path = '\\shell\\[^\\]+\\command(\\|$)' }
    @{ Path = '\\(ShellExecuteHooks|Browser Helper Objects|ShellServiceObjectDelayLoad)(\\|$)' }
)

function Test-WinForgeRegistryTargetAllowed {
    param([string] $Path, [string] $Name)
    foreach ($rule in $script:WinForgeDeniedRegistry) {
        if ($Path -match $rule.Path) {
            if (-not $rule.ContainsKey('Names') -or $Name -match $rule.Names) { return $false }
        }
    }
    return $true
}

function Test-WinForgeTarget {
    param($Target, [string] $Owner, $Errors)

    $type = Get-WinForgeField $Target 'Type'
    $allowed = @{
        Registry        = @('Type','Hive','Path','Name','Kind','Value')
        Service         = @('Type','Name','Value')
        ScheduledTask   = @('Type','Path','Name','Value')
        OptionalFeature = @('Type','Name','Value')
        Appx            = @('Type','Name')
    }
    if (-not $allowed.ContainsKey([string]$type)) { $Errors.Add("${Owner}: invalid Target.Type '$type'"); return }
    foreach ($f in $Target.PSObject.Properties.Name) {
        if ($allowed[$type] -notcontains $f) { $Errors.Add("${Owner}: $type target has unknown field '$f'") }
    }

    $name  = [string](Get-WinForgeField $Target 'Name')
    $value = Get-WinForgeField $Target 'Value'
    $wild  = '[\*\?\[\]]'

    switch ($type) {
        'Registry' {
            $hive = Get-WinForgeField $Target 'Hive'
            $path = [string](Get-WinForgeField $Target 'Path')
            $kind = Get-WinForgeField $Target 'Kind'
            if (@('HKLM','HKCU') -notcontains $hive) { $Errors.Add("${Owner}: invalid Hive '$hive'") }
            if (-not $path -or $path -match '^\\' -or $path -match '(^|\\)\.\.(\\|$)' -or $path -match $wild -or $path -match ':') {
                $Errors.Add("${Owner}: invalid registry Path '$path'")
            }
            if (-not $name -or $name -match $wild) { $Errors.Add("${Owner}: invalid registry value Name '$name'") }
            if (@('DWord','QWord','String','ExpandString','MultiString','Binary') -notcontains $kind) { $Errors.Add("${Owner}: invalid Kind '$kind'") }
            if ($Target.PSObject.Properties.Name -notcontains 'Value') { $Errors.Add("${Owner}: registry target has no Value") }
            elseif ($kind -in @('DWord','QWord') -and -not ($value -is [int] -or $value -is [long])) { $Errors.Add("${Owner}: $kind Value must be an integer") }
            elseif ($kind -in @('String','ExpandString') -and $value -isnot [string]) { $Errors.Add("${Owner}: $kind Value must be a string") }
            elseif ($kind -eq 'MultiString' -and @($value | Where-Object { $_ -isnot [string] }).Count -gt 0) { $Errors.Add("${Owner}: MultiString Value must be strings") }
            elseif ($kind -eq 'Binary' -and @($value | Where-Object { -not ($_ -is [int] -or $_ -is [long]) -or $_ -lt 0 -or $_ -gt 255 }).Count -gt 0) { $Errors.Add("${Owner}: Binary Value must be bytes") }
            if ($path -and $name -and -not (Test-WinForgeRegistryTargetAllowed -Path $path -Name $name)) {
                $Errors.Add("${Owner}: registry location '$hive\$path\$name' can launch code or disable core protections and is not allowed")
            }
        }
        'Service' {
            if ($name -notmatch '^[A-Za-z0-9_.-]{1,80}$') { $Errors.Add("${Owner}: invalid service Name '$name'") }
            if (@('Automatic','Manual','Disabled') -notcontains $value) { $Errors.Add("${Owner}: invalid service start type '$value'") }
        }
        'ScheduledTask' {
            $path = [string](Get-WinForgeField $Target 'Path')
            if ($path -notmatch '^\\([^\\]+\\)*$' -or $path -match $wild -or $path -match '(^|\\)\.\.(\\|$)') { $Errors.Add("${Owner}: invalid task Path '$path'") }
            if (-not $name -or $name -match $wild -or $name -match '\\') { $Errors.Add("${Owner}: invalid task Name '$name'") }
            if (@('Disabled','Ready') -notcontains $value) { $Errors.Add("${Owner}: invalid task state '$value'") }
        }
        'OptionalFeature' {
            if ($name -notmatch '^[A-Za-z0-9._-]{1,128}$') { $Errors.Add("${Owner}: invalid feature Name '$name'") }
            if (@('Enabled','Disabled') -notcontains $value) { $Errors.Add("${Owner}: invalid feature state '$value'") }
        }
        'Appx' {
            if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$') { $Errors.Add("${Owner}: invalid Appx Name '$name' (wildcards are not allowed)") }
        }
    }
}

function Test-WinForgeAppCatalog {
    param($Context, $Errors)
    $appsPath = Join-Path $Context.CatalogRoot 'apps.json'
    $bundlesPath = Join-Path $Context.CatalogRoot 'bundles.json'
    if (-not (Test-Path -LiteralPath $appsPath)) { return }
    try { $apps = Read-WinForgeJson $appsPath } catch { $Errors.Add("apps.json: invalid JSON ($($_.Exception.Message))"); return }

    # Provider IDs are passed to winget/choco as arguments. Anything that could be parsed
    # as an option ('--source=...') or contains whitespace or quotes is rejected.
    $pkgId = '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$'
    $ids = @{}
    foreach ($a in @(Get-WinForgeField $apps 'apps')) {
        $id = [string](Get-WinForgeField $a 'Id')
        if ($id -notmatch '^[a-z0-9][a-z0-9-]{1,63}$') { $Errors.Add("app '$id': invalid Id") }
        if ($ids.ContainsKey($id)) { $Errors.Add("app '$id': duplicate Id") } else { $ids[$id] = $true }
        $prov = Get-WinForgeField $a 'Providers'
        if (-not $prov) { $Errors.Add("app '$id': no Providers"); continue }
        foreach ($p in $prov.PSObject.Properties) {
            if (@('winget','choco') -notcontains $p.Name) { $Errors.Add("app '$id': unknown provider '$($p.Name)'") }
            elseif ($null -ne $p.Value -and [string]$p.Value -notmatch $pkgId) { $Errors.Add("app '$id': invalid $($p.Name) package ID '$($p.Value)'") }
        }
    }
    if (Test-Path -LiteralPath $bundlesPath) {
        try { $b = Read-WinForgeJson $bundlesPath } catch { $Errors.Add("bundles.json: invalid JSON ($($_.Exception.Message))"); return }
        foreach ($bundle in @(Get-WinForgeField $b 'bundles')) {
            foreach ($appId in @(Get-WinForgeField $bundle 'Apps')) {
                if ($appId -and -not $ids.ContainsKey($appId)) { $Errors.Add("bundle '$($bundle.Id)': unknown app '$appId'") }
            }
        }
    }
}

function Test-WinForgeCatalog {
    param($Context)

    $errors = New-Object System.Collections.Generic.List[string]
    $topFields       = @('Id','Name','Description','Category','Risk','Reversible','MinBuild','MaxBuild','Editions','Architecture','NeedsRestart','SourceUrl','Notes','Targets','Verification','Undo')
    $required        = @('Id','Name','Description','Category','Risk','Reversible','Targets','NeedsRestart','Verification','Undo')
    $validCategory   = @('Debloat','Privacy','Security','System','Taskbar','Start','Explorer')
    $validRisk       = @('Safe','Caution','Danger')
    $validReversible = @('full','partial','none')
    $validVerify     = @('RegistryEquals','ServiceStartTypeEquals','TaskStateEquals','FeatureStateEquals','AppxAbsent')
    $validUndo       = @('RestoreCapturedState','ReinstallAppx','Manual','None')

    $tweaksPath = Join-Path $Context.CatalogRoot 'tweaks.json'
    if (-not (Test-Path -LiteralPath $tweaksPath)) {
        $errors.Add('Missing tweaks.json')
        return [pscustomobject]@{ Valid = $false; Errors = $errors }
    }
    try { $doc = Read-WinForgeJson $tweaksPath }
    catch {
        $errors.Add("tweaks.json: invalid JSON ($($_.Exception.Message))")
        return [pscustomobject]@{ Valid = $false; Errors = $errors }
    }

    $seen = @{}
    foreach ($t in @(Get-WinForgeField $doc 'tweaks')) {
        if ($t -isnot [psobject]) { $errors.Add('tweaks.json: entry is not an object'); continue }
        $id = [string](Get-WinForgeField $t 'Id')
        $props = @($t.PSObject.Properties.Name)
        foreach ($req in $required) {
            if ($props -notcontains $req) { $errors.Add("${id}: missing required field '$req'") }
        }
        foreach ($p in $props) {
            if (@('Script','Command','CommandLine','ScriptBlock','Expression') -contains $p) { $errors.Add("${id}: free-form execution field '$p' is forbidden") }
            elseif ($topFields -notcontains $p) { $errors.Add("${id}: unknown field '$p'") }
        }
        if ($id -notmatch '^[a-z0-9][a-z0-9-]{2,63}$') { $errors.Add("${id}: invalid Id format") }
        if ($seen.ContainsKey($id)) { $errors.Add("${id}: duplicate Id") } else { $seen[$id] = $t }

        $risk = Get-WinForgeField $t 'Risk'
        $rev  = Get-WinForgeField $t 'Reversible'
        $undo = Get-WinForgeField (Get-WinForgeField $t 'Undo') 'Strategy'
        if ($validCategory -notcontains (Get-WinForgeField $t 'Category')) { $errors.Add("${id}: invalid Category") }
        if ($validRisk -notcontains $risk) { $errors.Add("${id}: invalid Risk '$risk'") }
        if ($validReversible -notcontains $rev) { $errors.Add("${id}: invalid Reversible '$rev'") }
        if ($validVerify -notcontains (Get-WinForgeField (Get-WinForgeField $t 'Verification') 'Type')) { $errors.Add("${id}: invalid Verification.Type") }
        if ($validUndo -notcontains $undo) { $errors.Add("${id}: invalid Undo.Strategy") }
        if ((Get-WinForgeField $t 'NeedsRestart') -isnot [bool]) { $errors.Add("${id}: NeedsRestart must be true or false") }
        foreach ($b in 'MinBuild','MaxBuild') {
            $v = Get-WinForgeField $t $b
            if ($null -ne $v -and -not ($v -is [int] -or $v -is [long])) { $errors.Add("${id}: $b must be an integer") }
        }
        foreach ($e in @(Get-WinForgeField $t 'Editions')) {
            if ($e -and @('Home','Pro','Enterprise','Education') -notcontains $e) { $errors.Add("${id}: invalid edition '$e'") }
        }
        foreach ($a in @(Get-WinForgeField $t 'Architecture')) {
            if ($a -and @('x64','ARM64') -notcontains $a) { $errors.Add("${id}: invalid architecture '$a'") }
        }
        $url = Get-WinForgeField $t 'SourceUrl'
        if ($url -and $url -notmatch '^https://') { $errors.Add("${id}: SourceUrl must be https") }

        $targets = @(Get-WinForgeField $t 'Targets')
        if ($targets.Count -lt 1 -or $null -eq $targets[0]) { $errors.Add("${id}: no Targets") }
        else { foreach ($tg in $targets) { Test-WinForgeTarget -Target $tg -Owner $id -Errors $errors } }

        # Labels must match what the engine can actually do.
        $hasAppx = @($targets | Where-Object { (Get-WinForgeField $_ 'Type') -eq 'Appx' }).Count -gt 0
        if ($hasAppx -and $undo -eq 'RestoreCapturedState') { $errors.Add("${id}: Appx removal cannot use RestoreCapturedState") }
        if ($hasAppx -and $rev -eq 'full') { $errors.Add("${id}: Appx removal cannot be labelled fully reversible") }
        if ($undo -in @('Manual','None') -and $rev -eq 'full') { $errors.Add("${id}: Undo '$undo' contradicts Reversible 'full'") }
    }

    $profPath = Join-Path $Context.CatalogRoot 'profiles.json'
    if (Test-Path -LiteralPath $profPath) {
        try { $pd = Read-WinForgeJson $profPath } catch { $pd = $null; $errors.Add("profiles.json: invalid JSON ($($_.Exception.Message))") }
        foreach ($p in @(Get-WinForgeField $pd 'profiles')) {
            $pid_ = Get-WinForgeField $p 'Id'
            foreach ($tid in @(Get-WinForgeField $p 'TweakIds')) {
                if (-not $seen.ContainsKey([string]$tid)) { $errors.Add("profile '$pid_': unknown tweak '$tid'"); continue }
                if ((Get-WinForgeField $seen[$tid] 'Risk') -eq 'Danger') { $errors.Add("profile '$pid_': Danger tweak '$tid' is forbidden in profiles") }
            }
        }
    }

    Test-WinForgeAppCatalog -Context $Context -Errors $errors
    return [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = $errors }
}

function Assert-WinForgeCatalog {
    # Every engine entry point calls this, so a hand-edited or downloaded catalog that
    # fails validation can never reach an adapter.
    param($Context)
    $r = Test-WinForgeCatalog -Context $Context
    if (-not $r.Valid) { throw ("Catalog failed validation; refusing to continue:`n  " + ($r.Errors -join "`n  ")) }
}
