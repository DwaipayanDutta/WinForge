$script:WinForgeVersion = '0.1.0'

function New-WinForgeStateAcl {
    # SYSTEM and Administrators: full control. Users: read only. Run records drive
    # elevated Undo, so a non-elevated process must not be able to write them.
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $system = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
    $users  = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none    = [Security.AccessControl.PropagationFlags]::None
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $system, $admins) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $none, 'Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', $inherit, $none, 'Allow')))
    return $acl
}

function Protect-WinForgeStateRoot {
    param([string] $Path)
    Set-Acl -LiteralPath $Path -AclObject (New-WinForgeStateAcl)
    # Anything created before hardening (e.g. by a non-elevated run) is re-owned and
    # reset to inherit only the protected root ACL.
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    foreach ($child in Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue) {
        $c = if ($child.PSIsContainer) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
        $c.SetOwner($admins)
        $c.SetAccessRuleProtection($false, $false)
        Set-Acl -LiteralPath $child.FullName -AclObject $c
    }
}

function New-WinForgeContext {
    [CmdletBinding()]
    param([string] $StateRoot)

    $root = Split-Path -Parent $PSScriptRoot
    $elevated = ([Security.Principal.WindowsPrincipal](
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $portableState = Join-Path $root 'state'
    $isDefault = $false
    if (-not $StateRoot) {
        if (Test-Path -LiteralPath $portableState) { $StateRoot = $portableState }
        else { $StateRoot = Join-Path $env:ProgramData 'WinForge'; $isDefault = $true }
    }

    $ctx = [pscustomobject]@{
        Root        = $root
        Version     = $script:WinForgeVersion
        CatalogRoot = Join-Path $root 'Catalog'
        StateRoot   = $StateRoot
        LogDir      = Join-Path $StateRoot 'logs'
        RunDir      = Join-Path $StateRoot 'runs'
        BackupDir   = Join-Path $StateRoot 'backups'
        IsPortable  = ($StateRoot -eq $portableState)
        Elevated    = $elevated
        StateWritable = $true
    }

    if ($isDefault -and -not $elevated) {
        # Never create the shared state folder from a non-elevated process: it would be
        # owned by the user. Read what exists; logs for read-only commands are skipped.
        $ctx.StateWritable = $false
        return $ctx
    }

    foreach ($d in @($ctx.StateRoot, $ctx.LogDir, $ctx.RunDir, $ctx.BackupDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    if ($isDefault -and $elevated) { Protect-WinForgeStateRoot -Path $ctx.StateRoot }
    return $ctx
}
