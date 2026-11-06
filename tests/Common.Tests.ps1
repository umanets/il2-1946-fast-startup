#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
<#
    Offline tests for il2-1946-fast-startup. These NEVER touch the real Windows registry:
    every test injects an in-memory fake backend (New-FakeRegistryBackend) and uses a
    temporary backup directory ($TestDrive). Safe to run in CI on any Windows host.
#>
BeforeAll {
    $script:ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Common.psm1'
    Import-Module $script:ModulePath -Force
    $script:Exe = 'C:\Games\IL-2 1946\il2fb.exe'

    function script:New-TestBackend {
        param($Cu, $Lm, [switch]$FailHKLM)
        $init = @{ HKCU = @{}; HKLM = @{} }
        if ($null -ne $Cu) { $init.HKCU[$script:Exe] = $Cu }
        if ($null -ne $Lm) { $init.HKLM[$script:Exe] = $Lm }
        New-FakeRegistryBackend -Initial $init -FailHKLMWrite:$FailHKLM
    }
    function script:CuData($b) { if ($b.Store['HKCU'].ContainsKey($script:Exe)) { $b.Store['HKCU'][$script:Exe].Data } else { $null } }
    function script:LmData($b) { if ($b.Store['HKLM'].ContainsKey($script:Exe)) { $b.Store['HKLM'][$script:Exe].Data } else { $null } }
}

Describe 'Pure parsing/decision logic' {
    It 'treats empty/null value as nothing to do' {
        (Resolve-LayerRemoval -Data '').Action    | Should -Be 'None'
        (Resolve-LayerRemoval -Data $null).Action | Should -Be 'None'
    }
    It 'removes a lone problem layer by deleting the value' {
        (Resolve-LayerRemoval -Data 'DWM8And16BitMitigation').Action | Should -Be 'Delete'
    }
    It 'deletes when only the "$" control prefix would remain' {
        $r = Resolve-LayerRemoval -Data '$ DWM8And16BitMitigation'
        $r.Action | Should -Be 'Delete'
    }
    It 'preserves another layer (Modify)' {
        $r = Resolve-LayerRemoval -Data 'HIGHDPIAWARE DWM8And16BitMitigation'
        $r.Action  | Should -Be 'Modify'
        $r.NewData | Should -BeExactly 'HIGHDPIAWARE'
    }
    It 'preserves control prefix AND other layer' {
        (Resolve-LayerRemoval -Data '~ HIGHDPIAWARE DWM8And16BitMitigation').NewData | Should -BeExactly '~ HIGHDPIAWARE'
        (Resolve-LayerRemoval -Data '$ DWM8And16BitMitigation RUNASADMIN').NewData   | Should -BeExactly '$ RUNASADMIN'
    }
    It 'is a no-op when the problem layer is absent' {
        (Resolve-LayerRemoval -Data 'HIGHDPIAWARE').Action | Should -Be 'None'
    }
    It 'flags an unfamiliar value but still computes a safe removal (keeps the unknown token)' {
        $r = Resolve-LayerRemoval -Data 'weird??tok DWM8And16BitMitigation'
        $r.Unfamiliar | Should -BeTrue
        $r.Action     | Should -Be 'Modify'
        $r.NewData    | Should -BeExactly 'weird??tok'
    }
    It 'matches the problem layer case-insensitively' {
        (Resolve-LayerRemoval -Data 'dwm8and16bitmitigation').Action | Should -Be 'Delete'
    }
    It 'validates executable paths' {
        Test-ValidExePath 'C:\x\il2fb.exe' | Should -BeTrue
        Test-ValidExePath ''               | Should -BeFalse
        Test-ValidExePath 'C:\x\folder'    | Should -BeFalse
    }
}

Describe 'Real backend robustness (regression: reg.exe stderr under ErrorAction Stop)' {
    It 'Get on an absent value returns Present=$false and does NOT throw under Stop' {
        $ErrorActionPreference = 'Stop'
        $rb = New-RealRegistryBackend
        $r = $null
        { $r = & $rb.Get 'HKCU' 'C:\no\such\path\xyzzy_il2fb_test.exe' } | Should -Not -Throw
        $r.Present | Should -BeFalse
    }
    It 'List does not throw under Stop (read-only)' {
        $ErrorActionPreference = 'Stop'
        $rb = New-RealRegistryBackend
        { [void](& $rb.List 'HKCU') } | Should -Not -Throw
    }
}

Describe 'Elevation argument building (regression: quoting + switches)' {
    It 'quotes the script/game paths and includes only true switches' {
        $s = Get-ElevationArgString -ScriptPath 'C:\a b\restore.ps1' -Arguments ([ordered]@{ GamePath='C:\g h\il2fb.exe'; Force=$false; NoElevate=$true })
        $s | Should -BeLike '*-File "C:\a b\restore.ps1"*'
        $s | Should -BeLike '*-GamePath "C:\g h\il2fb.exe"*'
        $s | Should -BeLike '*-NoElevate*'
        $s | Should -Not -BeLike '*-Force*'
    }
}

Describe 'Get-Il2LayerState (read-only)' {
    It 'reports problem present for HKCU-only' {
        $b = New-TestBackend 'DWM8And16BitMitigation' $null
        $s = Get-Il2LayerState -ExePath $Exe -Backend $b
        $s.ProblemPresent      | Should -BeTrue
        $s.HKCU.ContainsProblem | Should -BeTrue
        $s.HKLM.Present         | Should -BeFalse
    }
    It 'reports not-present when no entries' {
        (Get-Il2LayerState -ExePath $Exe -Backend (New-TestBackend $null $null)).ProblemPresent | Should -BeFalse
    }
    It 'reports preserved other layers' {
        $s = Get-Il2LayerState -ExePath $Exe -Backend (New-TestBackend 'HIGHDPIAWARE DWM8And16BitMitigation' $null)
        $s.HKCU.OtherLayers | Should -Contain 'HIGHDPIAWARE'
    }
}

Describe 'Invoke-ApplyFix' {
    BeforeEach { $script:Bk = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
    It 'HKCU-only: removes value, leaves HKLM absent, writes backup' {
        $b = New-TestBackend 'DWM8And16BitMitigation' $null
        $r = Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk
        $r.Changed  | Should -BeTrue
        $r.Verified | Should -BeTrue
        CuData $b   | Should -BeNullOrEmpty
        LmData $b   | Should -BeNullOrEmpty
        Test-Path (Get-BackupPath $Exe $Bk) | Should -BeTrue
    }
    It 'HKLM-only ($ prefix): removes value' {
        $b = New-TestBackend $null '$ DWM8And16BitMitigation'
        (Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk).Verified | Should -BeTrue
        LmData $b | Should -BeNullOrEmpty
    }
    It 'both entries: removes both (matches the real experiment)' {
        $b = New-TestBackend 'DWM8And16BitMitigation' '$ DWM8And16BitMitigation'
        $r = Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk
        $r.Verified | Should -BeTrue
        CuData $b | Should -BeNullOrEmpty
        LmData $b | Should -BeNullOrEmpty
    }
    It 'no entries: no-op, no backup' {
        $b = New-TestBackend $null $null
        $r = Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk
        $r.Changed | Should -BeFalse
        Test-Path (Get-BackupPath $Exe $Bk) | Should -BeFalse
    }
    It 'already fixed (other layer only): no-op' {
        $b = New-TestBackend 'HIGHDPIAWARE' $null
        (Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk).Changed | Should -BeFalse
        CuData $b | Should -BeExactly 'HIGHDPIAWARE'
    }
    It 'multiple flags: preserves the others' {
        $b = New-TestBackend 'HIGHDPIAWARE DWM8And16BitMitigation' '$ DWM8And16BitMitigation RUNASADMIN'
        Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        CuData $b | Should -BeExactly 'HIGHDPIAWARE'
        LmData $b | Should -BeExactly '$ RUNASADMIN'
    }
    It 'is idempotent and preserves the first backup' {
        $b = New-TestBackend 'DWM8And16BitMitigation' '$ DWM8And16BitMitigation'
        Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        $second = Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk
        $second.Changed | Should -BeFalse
        (Read-LayerBackup -ExePath $Exe -BackupDir $Bk).original.HKLM.Data | Should -BeExactly '$ DWM8And16BitMitigation'
    }
    It 'refuses an unfamiliar value without -Force' {
        $b = New-TestBackend 'weird??tok DWM8And16BitMitigation' $null
        { Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk } | Should -Throw
    }
    It 'proceeds on an unfamiliar value with -Force (removing only the known token)' {
        $b = New-TestBackend 'weird??tok DWM8And16BitMitigation' $null
        Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk -Force | Out-Null
        CuData $b | Should -BeExactly 'weird??tok'
    }
    It 'rejects an invalid executable path' {
        { Invoke-ApplyFix -ExePath 'not-an-exe' -Backend (New-TestBackend $null $null) -BackupDir $Bk } | Should -Throw
    }
    It 'fails safely halfway (HKLM write error): auto-rolls back and keeps the durable backup' {
        $b = New-TestBackend 'DWM8And16BitMitigation' '$ DWM8And16BitMitigation' -FailHKLM
        { Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk } | Should -Throw
        CuData $b | Should -BeExactly 'DWM8And16BitMitigation'          # HKCU auto-restored
        LmData $b | Should -BeExactly '$ DWM8And16BitMitigation'        # HKLM untouched
        Test-Path (Get-BackupPath $Exe $Bk) | Should -BeTrue           # durable backup present for recovery
    }
}

Describe 'Invoke-Restore' {
    BeforeEach { $script:Bk = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
    It 'restores exact originals including the "$ " prefix' {
        $b = New-TestBackend 'DWM8And16BitMitigation' '$ DWM8And16BitMitigation'
        Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        (Invoke-Restore -ExePath $Exe -Backend $b -BackupDir $Bk).Restored | Should -BeTrue
        CuData $b | Should -BeExactly 'DWM8And16BitMitigation'
        LmData $b | Should -BeExactly '$ DWM8And16BitMitigation'
    }
    It 'restores an originally-absent value back to absent' {
        $b = New-TestBackend 'DWM8And16BitMitigation' $null   # HKLM originally absent
        Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        Invoke-Restore  -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        CuData $b | Should -BeExactly 'DWM8And16BitMitigation'
        LmData $b | Should -BeNullOrEmpty
    }
    It 'recovers from a durable backup after a simulated interruption' {
        $b = New-TestBackend 'DWM8And16BitMitigation' '$ DWM8And16BitMitigation'
        Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null   # changes applied, backup on disk
        # pretend the tool was interrupted; a later restore from the backup fully recovers
        Invoke-Restore -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        CuData $b | Should -BeExactly 'DWM8And16BitMitigation'
        LmData $b | Should -BeExactly '$ DWM8And16BitMitigation'
    }
    It 'is idempotent' {
        $b = New-TestBackend 'DWM8And16BitMitigation' $null
        Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        Invoke-Restore  -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        (Invoke-Restore -ExePath $Exe -Backend $b -BackupDir $Bk).Restored | Should -BeTrue
    }
    It 'throws when no backup exists' {
        { Invoke-Restore -ExePath $Exe -Backend (New-TestBackend $null $null) -BackupDir $Bk } | Should -Throw
    }
    It 'refuses to overwrite an externally changed value, unless -Force' {
        $b = New-TestBackend 'DWM8And16BitMitigation' '$ DWM8And16BitMitigation'
        Invoke-ApplyFix -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        & $b.Set 'HKCU' $Exe 'SOMEEXTERNALLAYER'                               # third party changes it
        { Invoke-Restore -ExePath $Exe -Backend $b -BackupDir $Bk } | Should -Throw
        Invoke-Restore -ExePath $Exe -Backend $b -BackupDir $Bk -Force | Out-Null
        CuData $b | Should -BeExactly 'DWM8And16BitMitigation'
    }
}

Describe 'DPI fix logic (Resolve-DpiEnable)' {
    It 'absent -> set HIGHDPIAWARE' {
        (Resolve-DpiEnable -Data '').NewData   | Should -BeExactly 'HIGHDPIAWARE'
        (Resolve-DpiEnable -Data $null).Action | Should -Be 'Set'
    }
    It 'already set -> None (idempotent, order-independent)' {
        (Resolve-DpiEnable -Data 'HIGHDPIAWARE').Action                         | Should -Be 'None'
        (Resolve-DpiEnable -Data 'HIGHDPIAWARE DWM8And16BitMitigation').Action | Should -Be 'None'
    }
    It 'preserves a non-DPI token' {
        (Resolve-DpiEnable -Data 'DWM8And16BitMitigation').NewData | Should -BeExactly 'DWM8And16BitMitigation HIGHDPIAWARE'
    }
    It 'replaces a conflicting DPI token' {
        (Resolve-DpiEnable -Data 'DPIUNAWARE').NewData | Should -BeExactly 'HIGHDPIAWARE'
    }
}

Describe 'Invoke-FixDpi / Invoke-RestoreDpi' {
    BeforeEach { $script:Bk = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
    It 'adds HIGHDPIAWARE to HKCU, leaves HKLM untouched, writes a tagged backup' {
        $b = New-TestBackend $null $null
        $r = Invoke-FixDpi -ExePath $Exe -Backend $b -BackupDir $Bk
        $r.Changed | Should -BeTrue; $r.Verified | Should -BeTrue
        CuData $b | Should -BeExactly 'HIGHDPIAWARE'
        LmData $b | Should -BeNullOrEmpty
        Test-Path (Get-BackupPath $Exe $Bk 'dpi') | Should -BeTrue
    }
    It 'is idempotent' {
        $b = New-TestBackend 'HIGHDPIAWARE' $null
        (Invoke-FixDpi -ExePath $Exe -Backend $b -BackupDir $Bk).Changed | Should -BeFalse
    }
    It 'preserves an existing non-DPI token' {
        $b = New-TestBackend 'DWM8And16BitMitigation' $null
        Invoke-FixDpi -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        CuData $b | Should -BeExactly 'DWM8And16BitMitigation HIGHDPIAWARE'
    }
    It 'its backup does not collide with the startup fix backup' {
        (Get-BackupPath $Exe $Bk 'dpi') | Should -Not -Be (Get-BackupPath $Exe $Bk)
    }
    It 'restore returns HKCU to original (absent)' {
        $b = New-TestBackend $null $null
        Invoke-FixDpi     -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        Invoke-RestoreDpi -ExePath $Exe -Backend $b -BackupDir $Bk | Out-Null
        CuData $b | Should -BeNullOrEmpty
    }
    It 'restore throws when there is no DPI backup' {
        { Invoke-RestoreDpi -ExePath $Exe -Backend (New-TestBackend $null $null) -BackupDir $Bk } | Should -Throw
    }
}
