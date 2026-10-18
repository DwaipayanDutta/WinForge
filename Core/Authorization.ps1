function Assert-OperationAuthorized {
    param($Tweak, [switch] $Expert, [string] $TypedConfirmation)

    if ($Tweak.Risk -ne 'Danger') { return }
    if (-not $Expert) {
        throw "Tweak '$($Tweak.Id)' is Danger-level and requires -Expert."
    }
    if ($TypedConfirmation -ne $Tweak.Id) {
        throw "Danger operation '$($Tweak.Id)' requires -TypedConfirmation $($Tweak.Id)."
    }
}