@{
    Severity     = @('Error','Warning')
    ExcludeRules = @(
        # Console output is the CLI's user interface.
        'PSAvoidUsingWriteHost'
        # Changes are gated by the engine itself (preview -> explicit confirmation ->
        # Expert gate -> run record), not by per-function -WhatIf/-Confirm.
        'PSUseShouldProcessForStateChangingFunctions'
        # Public function names (Test-TweakTargets, Get-WinForgeProviders, ...) are kept stable.
        'PSUseSingularNouns'
    )
}
