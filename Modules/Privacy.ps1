function Get-WinForgeTelemetryHonesty {
    $sys = Get-WinForgeSystemInfo
    return [pscustomobject]@{
        Edition = "$($sys.Edition) ($($sys.EditionId))"
        PolicyNote = switch ($sys.Edition) {
            'Home'       { 'AllowTelemetry 0 is treated as Required (1) on Home. WinForge cannot turn diagnostic data fully off on this edition.' }
            'Pro'        { 'AllowTelemetry 0 is treated as Required (1) on Pro. WinForge cannot turn diagnostic data fully off on this edition.' }
            'Enterprise' { 'Enterprise honours AllowTelemetry 0 (Security level).' }
            'Education'  { 'Education honours AllowTelemetry 0 (Security level).' }
            default      { "Edition '$($sys.EditionId)' is not recognised; the effective diagnostic level cannot be stated." }
        }
    }
}

function Show-WinForgePrivacySummary {
    param($Context)
    $h = Get-WinForgeTelemetryHonesty
    Write-Host 'Privacy posture' -ForegroundColor Cyan
    Write-Host ("  Edition: {0}" -f $h.Edition)
    Write-Host ("  Note:    {0}" -f $h.PolicyNote)
    $ids = (Get-WinForgeCatalog -Context $Context).tweaks | Where-Object Category -eq 'Privacy' | Select-Object -ExpandProperty Id
    foreach ($s in (Get-WinForgeAppliedState -Context $Context -TweakId $ids)) {
        Write-Host ("  {0,-45} {1}" -f $s.Id, $(if ($s.Applied) { 'applied' } else { 'not applied' }))
    }
}

function Invoke-WinForgePrivacyModule {
    param($Context, [switch] $Preview, [switch] $Force)
    $ids = (Get-WinForgeCatalog -Context $Context).tweaks |
        Where-Object { $_.Category -eq 'Privacy' -and $_.Risk -ne 'Danger' } |
        Select-Object -ExpandProperty Id
    if ($Preview) { Invoke-WinForgeOperation -Context $Context -TweakId $ids -Preview }
    else { Invoke-WinForgeOperation -Context $Context -TweakId $ids -Force:$Force }
}
