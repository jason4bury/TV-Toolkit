# PSScriptAnalyzer settings for TV Toolkit.
# Run: Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The functions are private GUI helpers inside one script, not exported cmdlets,
        # so -WhatIf/-Confirm support and singular nouns (Get-Duplicates, Get-MissingEpisodes)
        # add nothing here. Every rename, move and delete already asks first in the window.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # Event handlers and background-work callbacks have fixed signatures (sender and
        # event args; result, error and context), and not every handler uses every one.
        'PSReviewUnusedParameter'
    )
}
