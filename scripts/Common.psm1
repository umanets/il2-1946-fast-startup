<#
.SYNOPSIS
    Shared logic for il2-1946-fast-startup.

    All registry access goes through an injectable "backend" object so the logic
    can be unit-tested offline with an in-memory fake (see New-FakeRegistryBackend)
    without ever touching the real Windows registry.

    Scope of change: ONLY the per-executable value under
        HKCU\...\AppCompatFlags\Layers  and  HKLM\...\AppCompatFlags\Layers
    for the exact executable path the caller supplies. Only the
    "DWM8And16BitMitigation" token is removed; other layers and control prefixes
    are preserved. HKLM always uses the native 64-bit view, where the value lives.
#>
Set-StrictMode -Version 3.0

$script:ProblemLayer     = 'DWM8And16BitMitigation'
$script:LayersKeySuffix  = 'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$script:RegistryBackend  = $null

function Get-ProblemLayerName { $script:ProblemLayer }

# ---------------------------------------------------------------------------
# Pure parsing / decision logic (no registry, fully unit-testable)
# ---------------------------------------------------------------------------

function ConvertFrom-LayerValue {
    <# Classify the whitespace-separated tokens of an AppCompat Layers value. #>
    param([string]$Data)
    $tokens = @()
    if ($Data) { $tokens = @($Data -split '\s+' | Where-Object { $_ -ne '' }) }
    $classified = @(foreach ($t in $tokens) {
        $kind =
            if     ($t -ieq $script:ProblemLayer)  { 'problem' }
            elseif ($t -match '^[A-Za-z0-9_]+$')   { 'layer'   }   # layer names are alphanumeric
            elseif ($t -match '^[~!#\$@%\^&+]+$')  { 'prefix'  }   # control tokens, e.g. "$", "~"
            else                                   { 'unknown' }
        [pscustomobject]@{ Token = $t; Kind = $kind }
    })
    [pscustomobject]@{
        Tokens          = $classified
        HasUnknown      = [bool](@($classified | Where-Object { $_.Kind -eq 'unknown' }).Count)
        ContainsProblem = [bool](@($classified | Where-Object { $_.Kind -eq 'problem' }).Count)
        OtherLayers     = @($classified | Where-Object { $_.Kind -eq 'layer'  } | ForEach-Object Token)
        Prefixes        = @($classified | Where-Object { $_.Kind -eq 'prefix' } | ForEach-Object Token)
    }
}

function Resolve-LayerRemoval {
    <#
    Decide how to remove ONLY the problem layer from one value's data.
    Returns Action = None | Delete | Modify  (+ NewData, Unfamiliar, Reason).
      - None   : problem layer absent -> nothing to do.
      - Delete : nothing significant remains (only the problem layer and/or a bare prefix).
      - Modify : other tokens remain -> rewrite preserving prefixes + other tokens, in order.
    Unfamiliar=$true when a token could not be recognized; callers should refuse unless -Force.
    The removal itself is always safe: only the exact problem token is dropped, the rest kept verbatim.
    #>
    param([string]$Data)
    $p = ConvertFrom-LayerValue -Data $Data
    if (-not $p.ContainsProblem) {
        return [pscustomobject]@{ Action='None'; NewData=$Data; Unfamiliar=$p.HasUnknown; Reason='Problem layer not present' }
    }
    $remaining    = @($p.Tokens | Where-Object { $_.Kind -ne 'problem' }       | ForEach-Object Token)
    $significant  = @($p.Tokens | Where-Object { $_.Kind -in 'layer','unknown' } | ForEach-Object Token)
    if ($significant.Count -eq 0) {
        return [pscustomobject]@{ Action='Delete'; NewData=$null; Unfamiliar=$p.HasUnknown; Reason='Only the problem layer (and/or a control prefix) remained' }
    }
    [pscustomobject]@{ Action='Modify'; NewData=($remaining -join ' '); Unfamiliar=$p.HasUnknown; Reason='Removed problem layer; preserved other tokens' }
}

# "Run this program in compatibility mode for <old Windows>" tokens. These OS modes bundle the
# same DWM 8/16-bit mitigation, so they can re-introduce the slow thread-enumeration even after
# the standalone DWM8And16BitMitigation token is removed.
$script:OSCompatModes = @(
    'WIN95','WIN98','WINME',
    'WINXPSP1','WINXPSP2','WINXPSP3',
    'VISTARTM','VISTASP1','VISTASP2',
    'WIN7RTM','WIN8RTM','WIN81RTM',
    'WINSRV03SP1','WINSRV08SP1','WINSRV12RTM','WINSRV16RTM'
)

function Get-OSCompatModeTokens {
    <# Return any OS-version compatibility-mode tokens present in a Layers value (case-insensitive). #>
    param([string]$Data)
    $tokens = @()
    if ($Data) { $tokens = @($Data -split '\s+' | Where-Object { $_ -ne '' }) }
    @($tokens | Where-Object { $script:OSCompatModes -contains $_ })
}

function Test-ValidExePath {
    param([string]$ExePath)
    if ([string]::IsNullOrWhiteSpace($ExePath)) { return $false }
    if ($ExePath -notmatch '\.exe\s*$')          { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Registry backend abstraction
# ---------------------------------------------------------------------------

function Get-LayerKeyPath {
    param([ValidateSet('HKCU','HKLM')][string]$Scope)
    "$Scope\$script:LayersKeySuffix"
}

function New-RealRegistryBackend {
    <# Real backend using reg.exe. HKLM uses /reg:64 (the native view where the value lives).
       IMPORTANT: native stderr is sent to $null (NOT merged with 2>&1). reg.exe writes to
       stderr for a missing value; merging it with 2>&1 raises a terminating NativeCommandError
       under $ErrorActionPreference='Stop'. We discard stderr and drive all logic off exit codes. #>
    $get = {
        param($Scope,$Exe)
        $ErrorActionPreference = 'SilentlyContinue'   # reg.exe stderr must not terminate under caller's -Stop
        $a = @('query', (Get-LayerKeyPath $Scope), '/v', $Exe); if ($Scope -eq 'HKLM') { $a += '/reg:64' }
        $out = & reg.exe @a 2>$null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Present=$false; Type=$null; Data=$null } }
        foreach ($line in $out) {
            if ($line -match ([regex]::Escape($Exe) + '\s+(REG_\w+)\s+(.*)$')) {
                return [pscustomobject]@{ Present=$true; Type=$matches[1]; Data=($matches[2].TrimEnd()) }
            }
        }
        [pscustomobject]@{ Present=$false; Type=$null; Data=$null }
    }
    $set = {
        param($Scope,$Exe,$Data)
        $ErrorActionPreference = 'SilentlyContinue'
        $a = @('add', (Get-LayerKeyPath $Scope), '/v', $Exe, '/t', 'REG_SZ', '/d', $Data, '/f'); if ($Scope -eq 'HKLM') { $a += '/reg:64' }
        & reg.exe @a 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg add failed (exit $LASTEXITCODE) for $Scope '$Exe'" }
    }
    $remove = {
        param($Scope,$Exe)
        $ErrorActionPreference = 'SilentlyContinue'
        $a = @('delete', (Get-LayerKeyPath $Scope), '/v', $Exe, '/f'); if ($Scope -eq 'HKLM') { $a += '/reg:64' }
        & reg.exe @a 2>$null | Out-Null   # deleting a missing value returns non-zero; that is fine
    }
    $list = {
        param($Scope)
        $ErrorActionPreference = 'SilentlyContinue'
        $a = @('query', (Get-LayerKeyPath $Scope)); if ($Scope -eq 'HKLM') { $a += '/reg:64' }
        $out = & reg.exe @a 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $names = foreach ($line in $out) { if ($line -match '^\s+(.*?)\s+REG_\w+\s+') { $matches[1] } }
        @($names)
    }
    [pscustomobject]@{ Kind='real'; Get=$get; Set=$set; Remove=$remove; List=$list }
}

function New-FakeRegistryBackend {
    <# In-memory backend for tests. $Initial = @{ HKCU=@{ '<exe>'='<data>' }; HKLM=@{...} } #>
    param([hashtable]$Initial, [switch]$FailHKLMWrite)
    $store = @{ HKCU=@{}; HKLM=@{} }
    if ($Initial) {
        foreach ($scope in 'HKCU','HKLM') {
            if ($Initial.ContainsKey($scope) -and $Initial[$scope]) {
                foreach ($exe in $Initial[$scope].Keys) { $store[$scope][$exe] = @{ Type='REG_SZ'; Data=[string]$Initial[$scope][$exe] } }
            }
        }
    }
    $fail = [bool]$FailHKLMWrite
    $get = { param($Scope,$Exe)
        if ($store[$Scope].ContainsKey($Exe)) { [pscustomobject]@{ Present=$true; Type=$store[$Scope][$Exe].Type; Data=$store[$Scope][$Exe].Data } }
        else { [pscustomobject]@{ Present=$false; Type=$null; Data=$null } }
    }.GetNewClosure()
    $set = { param($Scope,$Exe,$Data)
        if ($fail -and $Scope -eq 'HKLM') { throw "simulated permission failure writing HKLM" }
        $store[$Scope][$Exe] = @{ Type='REG_SZ'; Data=[string]$Data }
    }.GetNewClosure()
    $remove = { param($Scope,$Exe)
        if ($fail -and $Scope -eq 'HKLM') { throw "simulated permission failure writing HKLM" }
        if ($store[$Scope].ContainsKey($Exe)) { [void]$store[$Scope].Remove($Exe) }
    }.GetNewClosure()
    $list = { param($Scope) @($store[$Scope].Keys) }.GetNewClosure()
    [pscustomobject]@{ Kind='fake'; Store=$store; Get=$get; Set=$set; Remove=$remove; List=$list }
}

function Set-RegistryBackend   { param($Backend) $script:RegistryBackend = $Backend }
function Clear-RegistryBackend  { $script:RegistryBackend = $null }
function Get-ActiveRegistryBackend {
    if ($null -ne $script:RegistryBackend) { return $script:RegistryBackend }
    New-RealRegistryBackend
}

function Invoke-BackendGet    { param($Backend,$Scope,$Exe)       & $Backend.Get    $Scope $Exe }
function Invoke-BackendSet    { param($Backend,$Scope,$Exe,$Data) & $Backend.Set    $Scope $Exe $Data }
function Invoke-BackendRemove { param($Backend,$Scope,$Exe)       & $Backend.Remove $Scope $Exe }
function Invoke-BackendList   { param($Backend,$Scope)           @(& $Backend.List $Scope) }

# ---------------------------------------------------------------------------
# High-level operations
# ---------------------------------------------------------------------------

function Get-Il2LayerState {
    <# Read-only. Returns per-scope state + whether the problem layer is present. #>
    param([Parameter(Mandatory)][string]$ExePath, $Backend)
    if (-not $Backend) { $Backend = Get-ActiveRegistryBackend }
    $scopes = @{}
    foreach ($scope in 'HKCU','HKLM') {
        $v = Invoke-BackendGet $Backend $scope $ExePath
        $p = ConvertFrom-LayerValue -Data $v.Data
        $scopes[$scope] = [pscustomobject]@{
            Scope=$scope; Present=$v.Present; Type=$v.Type; Data=$v.Data
            ContainsProblem = ($v.Present -and $p.ContainsProblem)
            OtherLayers = $p.OtherLayers; Prefixes = $p.Prefixes
            HasUnknown  = ($v.Present -and $p.HasUnknown)
            OSCompatModes = @(Get-OSCompatModeTokens $v.Data)
        }
    }
    [pscustomobject]@{
        ExePath=$ExePath; HKCU=$scopes['HKCU']; HKLM=$scopes['HKLM']
        OSCompatModePresent = ((@($scopes['HKCU'].OSCompatModes).Count + @($scopes['HKLM'].OSCompatModes).Count) -gt 0)
        ProblemPresent = ($scopes['HKCU'].ContainsProblem -or $scopes['HKLM'].ContainsProblem)
    }
}

function Get-BackupDirDefault { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'il2-1946-fast-startup\backups' }

function Get-ExeKey {
    param([string]$ExePath)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ExePath.ToLowerInvariant()))
    (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,16)
}

function Get-BackupPath {
    # Optional $Tag separates backups for different operations on the same exe
    # (e.g. the startup fix vs. the DPI fix) so they never clobber each other.
    param([string]$ExePath, [string]$BackupDir, [string]$Tag)
    if (-not $BackupDir) { $BackupDir = Get-BackupDirDefault }
    $suffix = if ($Tag) { '.' + $Tag } else { '' }
    Join-Path $BackupDir ((Split-Path $ExePath -Leaf) + '.' + (Get-ExeKey $ExePath) + $suffix + '.backup.json')
}

function Save-LayerBackup {
    param([string]$ExePath, $Original, $Applied, [string]$BackupDir, [string]$Tag)
    if (-not $BackupDir) { $BackupDir = Get-BackupDirDefault }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $path = Get-BackupPath $ExePath $BackupDir $Tag
    [ordered]@{ schema='il2fix-backup-v1'; exePath=$ExePath; createdUtc=(Get-Date).ToUniversalTime().ToString('o'); original=$Original; applied=$Applied } |
        ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
    $path
}

function Read-LayerBackup {
    param([string]$ExePath, [string]$BackupDir, [string]$Tag)
    $path = Get-BackupPath $ExePath $BackupDir $Tag
    if (-not (Test-Path $path)) { return $null }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Invoke-ApplyFix {
    <# Remove only DWM8And16BitMitigation for $ExePath. Durable backup written BEFORE changes. #>
    param([Parameter(Mandatory)][string]$ExePath, $Backend, [string]$BackupDir, [switch]$Force)
    if (-not (Test-ValidExePath $ExePath)) { throw "Invalid executable path: '$ExePath' (must be a non-empty path ending in .exe)" }
    if (-not $Backend) { $Backend = Get-ActiveRegistryBackend }

    $plan = @{}; $original = @{}
    foreach ($scope in 'HKCU','HKLM') {
        $v = Invoke-BackendGet $Backend $scope $ExePath
        $original[$scope] = @{ Present=$v.Present; Type=$v.Type; Data=$v.Data }
        if ($v.Present) {
            $res = Resolve-LayerRemoval -Data $v.Data
            if ($res.Unfamiliar -and -not $Force) { throw "Refusing: $scope value for '$ExePath' is unfamiliar ('$($v.Data)'). Re-run with -Force to override." }
            $plan[$scope] = $res
        } else {
            $plan[$scope] = [pscustomobject]@{ Action='None'; NewData=$null; Reason='absent' }
        }
    }

    $applied = @{}
    foreach ($scope in 'HKCU','HKLM') {
        switch ($plan[$scope].Action) {
            'Delete' { $applied[$scope] = @{ Present=$false; Type=$null;   Data=$null } }
            'Modify' { $applied[$scope] = @{ Present=$true;  Type='REG_SZ'; Data=$plan[$scope].NewData } }
            default  { $applied[$scope] = $original[$scope] }
        }
    }
    $changes = @($plan.Values | Where-Object { $_.Action -in 'Delete','Modify' })

    # DURABLE rollback point: write backup to disk BEFORE touching the registry.
    # Preserve the FIRST backup (true originals); never clobber it on re-runs.
    $existing = Read-LayerBackup -ExePath $ExePath -BackupDir $BackupDir
    $backupPath = Get-BackupPath $ExePath $BackupDir
    if (-not $existing -and $changes.Count -gt 0) {
        $backupPath = Save-LayerBackup -ExePath $ExePath -Original $original -Applied $applied -BackupDir $BackupDir
    }

    # Apply. On any failure, best-effort immediate rollback from the in-memory originals
    # (the durable JSON backup on disk is the independent backstop if even that fails,
    # e.g. the process is killed mid-way).
    try {
        foreach ($scope in 'HKCU','HKLM') {
            switch ($plan[$scope].Action) {
                'Delete' { Invoke-BackendRemove $Backend $scope $ExePath }
                'Modify' { Invoke-BackendSet    $Backend $scope $ExePath $plan[$scope].NewData }
            }
        }
    } catch {
        $applyError = $_.Exception.Message
        foreach ($scope in 'HKCU','HKLM') {
            try {
                $o = $original[$scope]
                if ($o.Present) { Invoke-BackendSet $Backend $scope $ExePath $o.Data } else { Invoke-BackendRemove $Backend $scope $ExePath }
            } catch { Write-Verbose "rollback step failed for ${scope}: $_" }
        }
        throw "Apply failed ($applyError). Rolled back in-memory where possible; durable backup kept at: $backupPath"
    }

    $ok = $true; $verify = @{}
    foreach ($scope in 'HKCU','HKLM') {
        $v = Invoke-BackendGet $Backend $scope $ExePath
        $e = $applied[$scope]
        $match = ($v.Present -eq $e.Present) -and ([string]$v.Data -ceq [string]$e.Data)
        if (-not $match) { $ok = $false }
        $verify[$scope] = [pscustomobject]@{ Scope=$scope; Match=$match; Expected=$e; Actual=@{Present=$v.Present;Data=$v.Data} }
    }
    [pscustomobject]@{ ExePath=$ExePath; Changed=($changes.Count -gt 0); Plan=$plan; Original=$original; Applied=$applied; BackupPath=$backupPath; Verified=$ok; Verify=$verify }
}

function Invoke-Restore {
    <# Restore exact original per-exe values from the durable backup. #>
    param([Parameter(Mandatory)][string]$ExePath, $Backend, [string]$BackupDir, [switch]$Force)
    if (-not (Test-ValidExePath $ExePath)) { throw "Invalid executable path: '$ExePath'" }
    if (-not $Backend) { $Backend = Get-ActiveRegistryBackend }
    $backup = Read-LayerBackup -ExePath $ExePath -BackupDir $BackupDir
    if (-not $backup) { throw "No backup found for '$ExePath'. Nothing to restore from. (Expected: $(Get-BackupPath $ExePath $BackupDir))" }

    $conflicts = @()
    foreach ($scope in 'HKCU','HKLM') {
        $orig = $backup.original.$scope; $appl = $backup.applied.$scope
        $cur  = Invoke-BackendGet $Backend $scope $ExePath
        $matchApplied  = ($cur.Present -eq $appl.Present) -and ([string]$cur.Data -ceq [string]$appl.Data)
        $matchOriginal = ($cur.Present -eq $orig.Present) -and ([string]$cur.Data -ceq [string]$orig.Data)
        if (-not ($matchApplied -or $matchOriginal)) {
            $conflicts += "$scope value '$($cur.Data)' was not set by this tool (expected applied='$($appl.Data)' or original='$($orig.Data)')."
        }
    }
    if ($conflicts.Count -gt 0 -and -not $Force) { throw ("Restore aborted - external changes detected. Re-run with -Force to overwrite:`n  " + ($conflicts -join "`n  ")) }

    foreach ($scope in 'HKCU','HKLM') {
        $orig = $backup.original.$scope
        if ($orig.Present) { Invoke-BackendSet $Backend $scope $ExePath $orig.Data }
        else               { Invoke-BackendRemove $Backend $scope $ExePath }
    }

    $ok = $true; $verify = @{}
    foreach ($scope in 'HKCU','HKLM') {
        $orig = $backup.original.$scope; $cur = Invoke-BackendGet $Backend $scope $ExePath
        $match = ($cur.Present -eq $orig.Present) -and ([string]$cur.Data -ceq [string]$orig.Data)
        if (-not $match) { $ok = $false }
        $verify[$scope] = [pscustomobject]@{ Scope=$scope; Match=$match; Expected=@{Present=$orig.Present;Data=$orig.Data}; Actual=@{Present=$cur.Present;Data=$cur.Data} }
    }
    [pscustomobject]@{ ExePath=$ExePath; Restored=$ok; BackupPath=(Get-BackupPath $ExePath $BackupDir); Verify=$verify }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevated {
    <#
    Re-launch the current script elevated (UAC), WAIT for it to finish, and return the result.
    The elevated worker writes a one-line status to -ResultFile; this reads it back so the
    original (non-elevated) console can report success/failure. Robust vs. the fire-and-forget
    pattern: the parent waits, captures the exit code, and surfaces the worker's outcome.
      $Arguments : name -> value hashtable; a [bool] $true becomes a switch (-Name), $false omitted.
    Returns [pscustomobject] @{ Launched; ExitCode; Result }.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$ResultFile
    )
    Remove-Item $ResultFile -ErrorAction SilentlyContinue
    $argString = Get-ElevationArgString -ScriptPath $ScriptPath -Arguments $Arguments
    $launched = $true; $exit = $null
    try {
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argString -PassThru -Wait -ErrorAction Stop
        $exit = $p.ExitCode
    } catch {
        $launched = $false   # UAC declined, or failed to start
    }
    $result = if (Test-Path $ResultFile) { (Get-Content $ResultFile -Raw).Trim() } else { $null }
    Remove-Item $ResultFile -ErrorAction SilentlyContinue
    [pscustomobject]@{ Launched = $launched; ExitCode = $exit; Result = $result }
}

function Get-ElevationArgString {
    <# Build a correctly-quoted powershell.exe argument string for the elevated worker.
       A [bool] $true argument becomes a switch (-Name); $false is omitted. Paths are quoted. #>
    param([string]$ScriptPath, [hashtable]$Arguments)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('-NoProfile -ExecutionPolicy Bypass -File "'); [void]$sb.Append($ScriptPath); [void]$sb.Append('"')
    foreach ($k in $Arguments.Keys) {
        $v = $Arguments[$k]
        if ($v -is [bool]) { if ($v) { [void]$sb.Append(" -$k") } }
        else                { [void]$sb.Append(" -$k `"$v`"") }
    }
    $sb.ToString()
}

function New-ResultFilePath {
    Join-Path ([IO.Path]::GetTempPath()) ('il2fix_' + [guid]::NewGuid().ToString('N') + '.result')
}

function Find-Il2Installation {
    <# Best-effort, read-only discovery from existing AppCompat Layers entries. #>
    param($Backend)
    if (-not $Backend) { $Backend = Get-ActiveRegistryBackend }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($scope in 'HKCU','HKLM') {
        foreach ($name in (Invoke-BackendList $Backend $scope)) {
            if ($name -match '\\il2fb\.exe$' -or $name -match '\\il2\.exe$') { [void]$found.Add($name) }
        }
    }
    @($found | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# High-DPI fix (independent of the startup fix): set the HIGHDPIAWARE layer so a
# DPI-unaware game is not bitmap-stretched when Windows scaling is > 100%.
# This is a per-user (HKCU) setting and needs no administrator. Backups are tagged
# 'dpi' so they never collide with the startup fix's backup.
# ---------------------------------------------------------------------------

$script:DpiLayer     = 'HIGHDPIAWARE'
$script:DpiAllTokens = @('HIGHDPIAWARE','DPIUNAWARE','GDIDPISCALING','DPIUNAWAREGDISCALED','PERPROCESSSYSTEMDPIFORCEON','PERPROCESSSYSTEMDPIFORCEOFF')

function Get-DpiLayerName { $script:DpiLayer }

function Resolve-DpiEnable {
    <# Ensure HIGHDPIAWARE is the DPI token (high-DPI override = 'Application'), preserving all
       non-DPI tokens/prefixes and replacing any conflicting DPI token. Returns Action None|Set. #>
    param([string]$Data)
    $tokens = @()
    if ($Data) { $tokens = @($Data -split '\s+' | Where-Object { $_ -ne '' }) }
    $hasHigh  = [bool](@($tokens | Where-Object { $_ -ieq $script:DpiLayer }).Count)
    $otherDpi = @($tokens | Where-Object { ($script:DpiAllTokens -contains $_) -and ($_ -ine $script:DpiLayer) })
    if ($hasHigh -and $otherDpi.Count -eq 0) {
        return [pscustomobject]@{ Action='None'; NewData=$Data; Reason='HIGHDPIAWARE already set' }
    }
    $kept = @($tokens | Where-Object { -not ($script:DpiAllTokens -contains $_) })
    [pscustomobject]@{ Action='Set'; NewData=((@($kept) + $script:DpiLayer) -join ' '); Reason='Set high-DPI override to Application' }
}

function Get-WindowsScalePercent {
    <# Best-effort primary-monitor scale (100/125/150/175/200). $null if unknown. #>
    try {
        $dpi = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction Stop).AppliedDPI
        if ($dpi) { [int][math]::Round(100.0 * $dpi / 96) } else { $null }
    } catch { $null }
}

function Invoke-FixDpi {
    <# Add HIGHDPIAWARE in HKCU (preserving other tokens). Durable tagged backup before change. #>
    param([Parameter(Mandatory)][string]$ExePath, $Backend, [string]$BackupDir)
    if (-not (Test-ValidExePath $ExePath)) { throw "Invalid executable path: '$ExePath'" }
    if (-not $Backend) { $Backend = Get-ActiveRegistryBackend }
    $scope = 'HKCU'
    $cur = Invoke-BackendGet $Backend $scope $ExePath
    $res = Resolve-DpiEnable -Data $cur.Data
    if ($res.Action -eq 'None') {
        return [pscustomobject]@{ ExePath=$ExePath; Changed=$false; Verified=$true; NewData=$cur.Data; BackupPath=$null }
    }
    $original = @{ HKCU = @{ Present=$cur.Present; Type=$cur.Type; Data=$cur.Data } }
    $applied  = @{ HKCU = @{ Present=$true; Type='REG_SZ'; Data=$res.NewData } }
    $backupPath = Get-BackupPath $ExePath $BackupDir 'dpi'
    if (-not (Read-LayerBackup -ExePath $ExePath -BackupDir $BackupDir -Tag 'dpi')) {
        $backupPath = Save-LayerBackup -ExePath $ExePath -Original $original -Applied $applied -BackupDir $BackupDir -Tag 'dpi'
    }
    try { Invoke-BackendSet $Backend $scope $ExePath $res.NewData }
    catch {
        $err = $_.Exception.Message
        try { if ($cur.Present) { Invoke-BackendSet $Backend $scope $ExePath $cur.Data } else { Invoke-BackendRemove $Backend $scope $ExePath } } catch { Write-Verbose "DPI rollback failed: $_" }
        throw "DPI apply failed ($err). Rolled back; durable backup at: $backupPath"
    }
    $v = Invoke-BackendGet $Backend $scope $ExePath
    $ok = $v.Present -and ([string]$v.Data -ceq [string]$res.NewData)
    [pscustomobject]@{ ExePath=$ExePath; Changed=$true; Verified=$ok; NewData=$res.NewData; BackupPath=$backupPath; Original=$original }
}

function Invoke-RestoreDpi {
    <# Restore the HKCU layer to the value saved by Invoke-FixDpi (tagged 'dpi'). #>
    param([Parameter(Mandatory)][string]$ExePath, $Backend, [string]$BackupDir, [switch]$Force)
    if (-not $Backend) { $Backend = Get-ActiveRegistryBackend }
    $backup = Read-LayerBackup -ExePath $ExePath -BackupDir $BackupDir -Tag 'dpi'
    if (-not $backup) { throw "No DPI backup found for '$ExePath'. (Expected: $(Get-BackupPath $ExePath $BackupDir 'dpi'))" }
    $scope = 'HKCU'
    $orig = $backup.original.$scope; $appl = $backup.applied.$scope
    $cur  = Invoke-BackendGet $Backend $scope $ExePath
    $mApplied = ($cur.Present -eq [bool]$appl.Present) -and ([string]$cur.Data -ceq [string]$appl.Data)
    $mOrig    = ($cur.Present -eq [bool]$orig.Present) -and ([string]$cur.Data -ceq [string]$orig.Data)
    if (-not ($mApplied -or $mOrig) -and -not $Force) { throw "DPI restore aborted - HKCU value '$($cur.Data)' was changed externally. Re-run with -Force to overwrite." }
    if ([bool]$orig.Present) { Invoke-BackendSet $Backend $scope $ExePath $orig.Data } else { Invoke-BackendRemove $Backend $scope $ExePath }
    $v = Invoke-BackendGet $Backend $scope $ExePath
    $ok = ($v.Present -eq [bool]$orig.Present) -and ([string]$v.Data -ceq [string]$orig.Data)
    [pscustomobject]@{ ExePath=$ExePath; Restored=$ok; BackupPath=(Get-BackupPath $ExePath $BackupDir 'dpi') }
}

Export-ModuleMember -Function *
