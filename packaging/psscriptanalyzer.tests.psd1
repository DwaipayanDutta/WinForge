@{
    Severity     = @('Error','Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        # Pester patterns the analyzer cannot follow: variables set in BeforeAll are used
        # in It blocks, mock parameters are bound by Pester, and mock state shared between
        # a mock body and its test has to live in global scope.
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSReviewUnusedParameter'
        'PSAvoidGlobalVars'
    )
}
