<#
.SYNOPSIS
    Remove ONLY the DWM8And16BitMitigation compatibility layer for the given IL-2 executable.
.DESCRIPTION
    Backs up the exact original HKCU/HKLM Layers values to a durable JSON file BEFORE changing
    anything, then removes only the problematic token (preserving other layers and control
    prefixes), verifies the result, and prints how to undo. When an HKLM change is required and
    the console is not elevated, it re-launches itself with UAC, WAITS for the elevated worker,
    and reports what happened. Does NOT touch game files. Safe to run repeatedly (idempotent).
.EXAMPLE
    .\apply-fix.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"
.PARAMETER Yes        Skip the confirmation prompt.
.PARAMETER Force      Proceed even if a value contains an unrecognized token.
.PARAMETER BackupDir  Override the backup directory (default: %LOCALAPPDATA%\il2-1946-fast-startup\backups).
.PARAMETER NoElevate  Do not self-elevate (used internally by the elevated worker and by tests).
.PARAMETER ResultFile Internal: elevated worker writes its one-line outcome here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [switch]$Yes,
    [switch]$Force,
    [string]$BackupDir,
    [switch]$NoElevate,
    [string]$ResultFile
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

function Write-Result([string]$text) { if ($ResultFile) { Set-Content -Path $ResultFile -Value $text -Encoding UTF8 } }

if (-not (Test-ValidExePath $GamePath)) { Write-Error "Not an .exe path: '$GamePath'"; Write-Result "ERROR: invalid path"; exit 2 }
$problem = Get-ProblemLayerName
$state = Get-Il2LayerState -ExePath $GamePath

if ($state.OSCompatModePresent) {
    Write-Host "WARNING: a Windows-version compatibility mode is set for this exe." -ForegroundColor Yellow
    Write-Host "It bundles the same DWM mitigation, so startup may stay slow even after this fix." -ForegroundColor Yellow
    Write-Host "For the fix to take effect, also turn OFF 'Run this program in compatibility mode'" -ForegroundColor Yellow
    Write-Host "(Properties -> Compatibility). This tool does not change that setting." -ForegroundColor Yellow
    Write-Host ""
}

if (-not $state.ProblemPresent) {
    Write-Host "Nothing to do: '$problem' is not assigned to '$GamePath' (already fixed or never set)." -ForegroundColor Green
    Write-Result "OK: nothing to do"
    exit 0
}

# Show exactly what will change.
Write-Host "Planned changes for: $GamePath" -ForegroundColor Cyan
foreach ($s in @($state.HKCU, $state.HKLM)) {
    if (-not $s.Present -or -not $s.ContainsProblem) { continue }
    $res = Resolve-LayerRemoval -Data $s.Data
    $after = switch ($res.Action) { 'Delete' { '(value removed)' } 'Modify' { "'$($res.NewData)'" } default { '(no change)' } }
    Write-Host ("  [{0}] '{1}'  ->  {2}" -f $s.Scope, $s.Data, $after)
    if ($res.Unfamiliar) { Write-Host "       value has an unrecognized token; requires -Force" -ForegroundColor Yellow }
}
Write-Host "Only the '$problem' token is removed. Other flags/prefixes are preserved." -ForegroundColor DarkGray
Write-Host "No game files are modified." -ForegroundColor DarkGray

if (-not $Yes) {
    $ans = Read-Host "Proceed with these registry changes? (y/N)"
    if ($ans -notmatch '^(y|yes)$') { Write-Host "Aborted. No changes made." -ForegroundColor Yellow; exit 1 }
}

$effBackupDir = if ($BackupDir) { $BackupDir } else { Get-BackupDirDefault }

# If HKLM must change and we are not elevated, re-launch elevated, WAIT, and report.
if ($state.HKLM.ContainsProblem -and -not (Test-IsAdmin) -and -not $NoElevate) {
    Write-Host "HKLM change requires administrator. Requesting UAC elevation and waiting..." -ForegroundColor Cyan
    $rf = New-ResultFilePath
    $e = Invoke-SelfElevated -ScriptPath $PSCommandPath -ResultFile $rf -Arguments @{
        GamePath = $GamePath; BackupDir = $effBackupDir; Yes = $true; Force = [bool]$Force; NoElevate = $true; ResultFile = $rf
    }
    if (-not $e.Launched) { Write-Warning "Elevation was cancelled or failed. No changes were made."; exit 1 }
    $after = Get-Il2LayerState -ExePath $GamePath
    Write-Host ("Elevated worker result: {0}" -f ($e.Result | ForEach-Object { $_ })) -ForegroundColor DarkGray
    if (-not $after.ProblemPresent) {
        Write-Host "Done. '$problem' is now removed (verified from this console)." -ForegroundColor Green
        Write-Host "To undo: .\restore.ps1 -GamePath `"$GamePath`"" -ForegroundColor DarkGray
        exit 0
    } else {
        Write-Error "The layer is still present after elevation. See the worker result above; try restore.ps1 / run as administrator."
        exit 1
    }
}

# Elevated worker (or already-admin / HKCU-only) path: do the work here.
try {
    $r = Invoke-ApplyFix -ExePath $GamePath -BackupDir $BackupDir -Force:$Force
} catch {
    Write-Result "ERROR: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
    exit 1
}
if ($r.BackupPath) { Write-Host "Backup written: $($r.BackupPath)" -ForegroundColor DarkGray }
if ($r.Verified) {
    Write-Host "Done. '$problem' removed and verified." -ForegroundColor Green
    Write-Host "To undo: .\restore.ps1 -GamePath `"$GamePath`"" -ForegroundColor DarkGray
    Write-Result "OK: removed and verified (backup=$($r.BackupPath))"
    exit 0
} else {
    Write-Error "Verification FAILED. Attempting restore from backup..."
    try { Invoke-Restore -ExePath $GamePath -BackupDir $BackupDir -Force | Out-Null; Write-Host "Restored original values." -ForegroundColor Yellow } catch { Write-Error "Restore also failed: $_. Run restore.ps1 manually." }
    Write-Result "ERROR: verification failed; attempted rollback"
    exit 1
}
