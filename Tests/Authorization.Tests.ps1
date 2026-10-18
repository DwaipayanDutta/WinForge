BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # Defined in BeforeAll, not the Describe body: Pester 5 discards Describe-body
    # variables before tests run, which made the original tests pass $null.
    $danger = [pscustomobject]@{ Id = 'security-disable-defender'; Risk = 'Danger' }
}

Describe 'Expert gate' {
    It 'rejects a Danger tweak without -Expert' {
        { Assert-OperationAuthorized -Tweak $danger } | Should -Throw '*requires -Expert*'
    }
    It 'rejects a Danger tweak without typed confirmation' {
        { Assert-OperationAuthorized -Tweak $danger -Expert -TypedConfirmation '' } | Should -Throw '*TypedConfirmation*'
    }
    It 'rejects a typed confirmation for a different tweak' {
        { Assert-OperationAuthorized -Tweak $danger -Expert -TypedConfirmation 'danger-other' } | Should -Throw '*TypedConfirmation*'
    }
    It 'accepts a Danger tweak with -Expert and matching confirmation' {
        { Assert-OperationAuthorized -Tweak $danger -Expert -TypedConfirmation 'security-disable-defender' } | Should -Not -Throw
    }
    It 'allows Safe tweaks without -Expert' {
        { Assert-OperationAuthorized -Tweak ([pscustomobject]@{ Id = 'privacy-disable-advertising-id'; Risk = 'Safe' }) } | Should -Not -Throw
    }
}

Describe 'Shipped profiles' {
    It 'contain no Danger tweak' {
        $ctx = New-WfTestContext
        $catalog = Get-WinForgeCatalog -Context $ctx
        $danger = @($catalog.tweaks | Where-Object Risk -eq 'Danger' | ForEach-Object Id)
        $danger.Count | Should -BeGreaterThan 0
        $profiles = (Get-Content (Join-Path $ctx.CatalogRoot 'profiles.json') -Raw | ConvertFrom-Json).profiles
        foreach ($p in $profiles) { @($p.TweakIds | Where-Object { $danger -contains $_ }) | Should -BeNullOrEmpty }
    }
}
