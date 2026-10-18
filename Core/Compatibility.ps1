function ConvertTo-WinForgeEditionFamily {
    # EditionID values (Core, Professional, EnterpriseS, ...) never match the catalog's
    # family names (Home, Pro, Enterprise, Education), so map them before comparing.
    param([string] $EditionId)
    switch -Regex ($EditionId) {
        '^Core'                       { return 'Home' }
        '^Professional'               { return 'Pro' }
        '^(Enterprise|IoTEnterprise)' { return 'Enterprise' }
        '^Education'                  { return 'Education' }
        '^Server'                     { return 'Server' }
        default                       { return 'Unknown' }
    }
}

function Test-WinForgeMdmEnrolled {
    # Intune / MDM enrollment is recorded under Enrollments with an MDM ProviderID.
    try {
        foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.PSObject.Properties['ProviderID'] -and $p.ProviderID -eq 'MS DM Server') { return $true }
        }
    } catch { Write-Verbose "MDM enrollment check unavailable: $($_.Exception.Message)" }
    return $false
}

function Get-WinForgeSystemInfo {
    $editionId = 'Unknown'
    try { $editionId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID }
    catch { Write-Verbose "EditionID unavailable: $($_.Exception.Message)" }

    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }; 'ARM64' { 'ARM64' }; default { $env:PROCESSOR_ARCHITECTURE }
    }

    $domain = $false
    try { $domain = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain }
    catch { Write-Verbose "Domain check unavailable: $($_.Exception.Message)" }
    $mdm = Test-WinForgeMdmEnrolled

    return [pscustomobject]@{
        Build         = [Environment]::OSVersion.Version.Build
        Edition       = ConvertTo-WinForgeEditionFamily $editionId
        EditionId     = $editionId
        Arch          = $arch
        Managed       = ($domain -or $mdm)
        ManagedReason = (@($(if ($domain) { 'domain-joined' }), $(if ($mdm) { 'MDM-enrolled' })) | Where-Object { $_ }) -join ', '
        Elevated      = ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

function Get-TweakProperty {
    param($Object, [string] $Name)
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Test-TweakCompatibility {
    param($Tweak, $SystemInfo)

    $min = Get-TweakProperty $Tweak 'MinBuild'
    if ($min -and $SystemInfo.Build -lt $min) {
        return [pscustomobject]@{ Supported = $false; Reason = "Requires build >= $min; current $($SystemInfo.Build)" }
    }
    $max = Get-TweakProperty $Tweak 'MaxBuild'
    if ($max -and $SystemInfo.Build -gt $max) {
        return [pscustomobject]@{ Supported = $false; Reason = "Requires build <= $max; current $($SystemInfo.Build)" }
    }
    $eds = Get-TweakProperty $Tweak 'Editions'
    if ($eds -and ($eds -notcontains $SystemInfo.Edition)) {
        return [pscustomobject]@{ Supported = $false; Reason = "Edition '$($SystemInfo.Edition)' not in supported list" }
    }
    $archs = Get-TweakProperty $Tweak 'Architecture'
    if ($archs -and ($archs -notcontains $SystemInfo.Arch)) {
        return [pscustomobject]@{ Supported = $false; Reason = "Architecture '$($SystemInfo.Arch)' not supported" }
    }
    if ($SystemInfo.Managed -and $Tweak.Risk -ne 'Safe') {
        return [pscustomobject]@{ Supported = $false; Reason = 'Managed device: only Safe tweaks permitted' }
    }
    return [pscustomobject]@{ Supported = $true; Reason = '' }
}
