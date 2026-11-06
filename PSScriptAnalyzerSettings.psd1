@{
    # PSScriptAnalyzer configuration for il2-1946-fast-startup.
    # Two rules are excluded as deliberate, documented false-positives for this project:
    ExcludeRules = @(
        # These are interactive, human-facing CLI scripts. Coloured console output via Write-Host
        # is intentional: it must go to the host, not the success/output stream (so it never
        # pollutes a function's return value or a pipeline). Machine-readable results are returned
        # as objects, not printed.
        'PSAvoidUsingWriteHost',

        # Fires on New-/Set- factory and accessor helpers (New-RealRegistryBackend,
        # New-FakeRegistryBackend, Set-RegistryBackend, New-ResultFilePath) that merely build an
        # object or set a module-scoped variable and do NOT change system state, so -WhatIf/-Confirm
        # would be noise. The functions that do change the registry use the Invoke-* verb and guard
        # changes with an explicit confirmation prompt / backup.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
