function Get-AppxState {
    param($Target)
    $pkg = Get-AppxPackage -Name $Target.Name -ErrorAction SilentlyContinue
    if (-not $pkg) { return [pscustomobject]@{ Existed = $false } }
    return [pscustomobject]@{ Existed = $true }
}

function Remove-AppxTarget {
    param($Target)
    Get-AppxPackage -Name $Target.Name -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction Stop
}

function Test-AppxTarget {
    param($Target)
    return (-not (Get-AppxState -Target $Target).Existed)
}