<#
.SYNOPSIS
    Restore the exact original AppCompat Layers values for the given IL-2 executable.
.DESCRIPTION
    Reads the durable backup written by apply-fix.ps1 and restores each per-executable value
    exactly (REG_SZ type and control tokens preserved; values that were originally absent are
    returned to absent). Refuses to overwrite values changed by something other than this tool
    unless -Force is given. Never touches unrelated registry entries. When an HKLM change is
    required and the console is not elevated, it re-launches with UAC, WAITS for the elevated
    worker, and reports the outcome (verified from the original console).
.EXAMPLE
    .\restore.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"
.PARAMETER Force      Overwrite values that were externally modified since apply-fix ran.
.PARAMETER BackupDir  Override the backup directory.
.PARAMETER NoElevate  Do not self-elevate (used internally by the elevated worker and by tests).
.PARAMETER ResultFile Internal: elevated worker writes its one-line outcome here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GamePath,
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

$backup = Read-LayerBackup -ExePath $GamePath -BackupDir $BackupDir
if (-not $backup) {
    Write-Error "No backup found for '$GamePath'."
    Write-Host "A backup is created only when apply-fix.ps1 makes a change. Expected location:" -ForegroundColor Yellow
    Write-Host "  $(Get-BackupPath $GamePath $BackupDir)" -ForegroundColor Yellow
    Write-Host "If you used a custom -BackupDir with apply-fix, pass the same -BackupDir here." -ForegroundColor Yellow
    Write-Host "Otherwise see docs/troubleshooting.md for restoring values manually." -ForegroundColor Yellow
    Write-Result "ERROR: no backup"
    exit 3
}

$effBackupDir = if ($BackupDir) { $BackupDir } else { Get-BackupDirDefault }

# Determine whether HKLM needs writing (original present, or a value currently exists there).
$curHklm = Invoke-BackendGet (Get-ActiveRegistryBackend) 'HKLM' $GamePath
$needHklm = ([bool]$backup.original.HKLM.Present) -or ([bool]$curHklm.Present)

if ($needHklm -and -not (Test-IsAdmin) -and -not $NoElevate) {
    Write-Host "HKLM restore requires administrator. Requesting UAC elevation and waiting..." -ForegroundColor Cyan
    $rf = New-ResultFilePath
    $e = Invoke-SelfElevated -ScriptPath $PSCommandPath -ResultFile $rf -Arguments @{
        GamePath = $GamePath; BackupDir = $effBackupDir; Force = [bool]$Force; NoElevate = $true; ResultFile = $rf
    }
    if (-not $e.Launched) { Write-Warning "Elevation was cancelled or failed. Nothing was changed."; exit 1 }
    Write-Host "---- elevated worker report (exit=$($e.ExitCode)) ----" -ForegroundColor DarkGray
    Write-Host ($e.Result) -ForegroundColor DarkGray
    Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray
    # Verify from this (original) console against the backup's originals.
    $okCU = $true; $okLM = $true
    foreach ($s in 'HKCU','HKLM') {
        $orig = $backup.original.$s
        $cur  = Invoke-BackendGet (Get-ActiveRegistryBackend) $s $GamePath
        $match = ($cur.Present -eq [bool]$orig.Present) -and ([string]$cur.Data -ceq [string]$orig.Data)
        if ($s -eq 'HKCU') { $okCU = $match } else { $okLM = $match }
    }
    if ($okCU -and $okLM) {
        Write-Host "Restored original values and verified from this console:" -ForegroundColor Green
        foreach ($s in 'HKCU','HKLM') { $o=$backup.original.$s; Write-Host ("  [{0}] -> {1}" -f $s, $(if ($o.Present) { "'$($o.Data)'" } else { '(absent)' })) }
        exit 0
    } else {
        Write-Error "Restore did not verify (HKCU ok=$okCU, HKLM ok=$okLM). See worker result above; you can re-run, or restore manually (docs/troubleshooting.md)."
        exit 5
    }
}

# Elevated worker (or already-admin) path: perform the restore here, with diagnostics.
$diag = New-Object System.Collections.Generic.List[string]
$diag.Add("IsAdmin=$(Test-IsAdmin)  User=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)")
$bp = Get-BackupPath $GamePath $BackupDir
$diag.Add("BackupDir='$BackupDir'")
$diag.Add("BackupPath='$bp' exists=$(Test-Path $bp)")
try {
    $r = Invoke-Restore -ExePath $GamePath -BackupDir $BackupDir -Force:$Force
    $diag.Add("Invoke-Restore.Restored=$($r.Restored)")
    foreach ($s in 'HKCU','HKLM') { $c = Invoke-BackendGet (Get-ActiveRegistryBackend) $s $GamePath; $diag.Add("post[$s] present=$($c.Present) data='$($c.Data)'") }
} catch {
    $diag.Add("EXCEPTION: $($_.Exception.Message)")
    Write-Result ($diag -join "`n")
    Write-Error $_.Exception.Message
    exit 4
}
Write-Result ($diag -join "`n")
if ($r.Restored) {
    Write-Host "Restored original values and verified:" -ForegroundColor Green
    foreach ($s in 'HKCU','HKLM') {
        $e = $r.Verify[$s].Expected
        Write-Host ("  [{0}] -> {1}" -f $s, $(if ($e.Present) { "'$($e.Data)'" } else { '(absent)' }))
    }
    exit 0
} else {
    Write-Error "Restore verification FAILED. Inspect manually (docs/troubleshooting.md)."
    exit 5
}
