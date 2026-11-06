<#
.SYNOPSIS
    Fix IL-2 1946's blurry / non-operable menu when Windows display scaling is > 100%.
.DESCRIPTION
    On a DPI-unaware game like IL-2 1946, Windows bitmap-stretches the window when the display
    scale is above 100%. The image becomes blurry and, in fullscreen, the menu mouse can mis-map
    so buttons do not respond. This sets the per-user (HKCU) 'HIGHDPIAWARE' AppCompat layer
    (equivalent to Properties > Compatibility > "Override high DPI scaling behavior" ->
    "Scaling performed by: Application"), so Windows renders the game at native resolution.

    Independent of the startup fix (apply-fix.ps1): it adds a different token (HIGHDPIAWARE),
    preserves any other flags, uses its own tagged backup, and needs NO administrator (HKCU only).
    No game files are modified.
.EXAMPLE
    .\fix-dpi.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"
.EXAMPLE
    .\fix-dpi.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe" -Restore
.PARAMETER Restore    Undo: restore the HKCU layer to the value saved when the fix was applied.
.PARAMETER BackupDir  Override the backup directory.
.PARAMETER Force      Overwrite an externally-changed value (on restore) / proceed on odd input.
.PARAMETER Yes        Skip the confirmation prompt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [switch]$Restore,
    [string]$BackupDir,
    [switch]$Force,
    [switch]$Yes
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

if (-not (Test-ValidExePath $GamePath)) { Write-Error "Not an .exe path: '$GamePath'"; exit 2 }

if ($Restore) {
    try { $r = Invoke-RestoreDpi -ExePath $GamePath -BackupDir $BackupDir -Force:$Force }
    catch { Write-Error $_.Exception.Message; exit 4 }
    if ($r.Restored) { Write-Host "DPI setting restored to its original value." -ForegroundColor Green; exit 0 }
    else { Write-Error "DPI restore did not verify. Inspect manually."; exit 5 }
}

$dpi = Get-DpiLayerName
$scale = Get-WindowsScalePercent
Write-Host "IL-2 1946 high-DPI fix" -ForegroundColor Cyan
Write-Host "Executable   : $GamePath"
if ($scale) {
    $note = if ($scale -gt 100) { " (scaling > 100% - a DPI-unaware game gets stretched/blurry and the fullscreen menu mouse can mis-map)" } else { " (at 100% this fix is usually unnecessary)" }
    Write-Host "Windows scale: ~$scale%$note"
}

$state = Get-Il2LayerState -ExePath $GamePath
Write-Host ("Current HKCU layer: {0}" -f $(if ($state.HKCU.Present) { "'$($state.HKCU.Data)'" } else { '(absent)' }))

$res = Resolve-DpiEnable -Data $state.HKCU.Data
if ($res.Action -eq 'None') { Write-Host "'$dpi' is already set. Nothing to do." -ForegroundColor Green; exit 0 }

Write-Host ("Will set HKCU layer to: '{0}'" -f $res.NewData)
Write-Host "Adds '$dpi' (high-DPI override = Application). Other flags are preserved." -ForegroundColor DarkGray
Write-Host "HKCU only -> no administrator needed. No game files are modified." -ForegroundColor DarkGray

if (-not $Yes) {
    $ans = Read-Host "Proceed? (y/N)"
    if ($ans -notmatch '^(y|yes)$') { Write-Host "Aborted. No changes made." -ForegroundColor Yellow; exit 1 }
}

$r = Invoke-FixDpi -ExePath $GamePath -BackupDir $BackupDir
if ($r.BackupPath) { Write-Host "Backup written: $($r.BackupPath)" -ForegroundColor DarkGray }
if ($r.Verified) {
    Write-Host "Done. HKCU layer = '$($r.NewData)'." -ForegroundColor Green
    Write-Host "Launch the game and check the menu. The UI appears smaller (native resolution) but sharp and clickable." -ForegroundColor DarkGray
    Write-Host "To undo: .\fix-dpi.ps1 -GamePath `"$GamePath`" -Restore" -ForegroundColor DarkGray
    exit 0
} else { Write-Error "Verification failed."; exit 1 }
