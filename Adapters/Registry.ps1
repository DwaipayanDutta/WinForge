function ConvertTo-RegistryPath {
    param($Target)
    $hive = if ($Target.Hive -eq 'HKLM') { 'HKLM:' } elseif ($Target.Hive -eq 'HKCU') { 'HKCU:' } else { throw "Unknown hive '$($Target.Hive)'" }
    return (Join-Path $hive $Target.Path)
}

function ConvertTo-RegistryValue {
    # Run records round-trip through JSON, which turns byte[] into object[] and ints into
    # Int64. Convert back to the exact .NET type the value kind needs.
    param($Value, [string] $Kind)
    switch ($Kind) {
        'DWord'       { return [int]$Value }
        'QWord'       { return [long]$Value }
        # Leading comma: stop PowerShell unrolling the array on return.
        'Binary'      { return ,([byte[]]@($Value)) }
        'MultiString' { return ,([string[]]@($Value)) }
        default       { return [string]$Value }
    }
}

function Get-RegistryState {
    param($Target)
    $keyPath = ConvertTo-RegistryPath -Target $Target
    if (-not (Test-Path -LiteralPath $keyPath)) { return [pscustomobject]@{ Existed = $false; KeyExisted = $false; Kind = $null; Value = $null } }
    $props = Get-ItemProperty -LiteralPath $keyPath -ErrorAction SilentlyContinue
    if (-not $props -or $props.PSObject.Properties.Name -notcontains $Target.Name) {
        return [pscustomobject]@{ Existed = $false; KeyExisted = $true; Kind = $null; Value = $null }
    }
    $item = Get-Item -LiteralPath $keyPath
    $kind = $item.GetValueKind($Target.Name).ToString()
    # DoNotExpandEnvironmentNames keeps REG_EXPAND_SZ values like %USERPROFILE%\x intact,
    # so Undo restores the original text rather than this user's expanded path.
    $value = $item.GetValue($Target.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($kind -eq 'Binary') { $value = [int[]]@($value) }
    return [pscustomobject]@{ Existed = $true; KeyExisted = $true; Kind = $kind; Value = $value }
}

function Set-RegistryTarget {
    param($Target)
    $keyPath = ConvertTo-RegistryPath -Target $Target
    if (-not (Test-Path -LiteralPath $keyPath)) { New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $keyPath -Name $Target.Name -Value (ConvertTo-RegistryValue $Target.Value $Target.Kind) -PropertyType $Target.Kind -Force -ErrorAction Stop | Out-Null
}

function Restore-RegistryState {
    param($Target, $Snapshot)
    $keyPath = ConvertTo-RegistryPath -Target $Target
    if ($Snapshot.Existed) {
        if (-not (Test-Path -LiteralPath $keyPath)) { New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $keyPath -Name $Target.Name -Value (ConvertTo-RegistryValue $Snapshot.Value $Snapshot.Kind) -PropertyType $Snapshot.Kind -Force -ErrorAction Stop | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $keyPath)) { return }
    Remove-ItemProperty -LiteralPath $keyPath -Name $Target.Name -ErrorAction SilentlyContinue
    # Remove the key too if WinForge created it and nothing else has been written there.
    $keyExisted = $Snapshot.PSObject.Properties['KeyExisted']
    if ($keyExisted -and $keyExisted.Value -eq $false) {
        $key = Get-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue
        if ($key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) { Remove-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue }
    }
}

function Test-RegistryTarget {
    param($Target)
    $s = Get-RegistryState -Target $Target
    if (-not $s.Existed -or $s.Kind -ne $Target.Kind) { return $false }
    return ((@($s.Value) -join "`n") -eq (@($Target.Value) -join "`n"))
}
