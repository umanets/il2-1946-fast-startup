<#
.SYNOPSIS
    Read-only diagnosis: is the DWM8And16BitMitigation compatibility layer assigned to IL-2?
.DESCRIPTION
    Inspects HKCU and HKLM ...\AppCompatFlags\Layers for the given executable and reports
    whether the known problematic layer is present, while preserving/reporting any other
    compatibility flags. Makes NO changes. Does not require administrator for read-only checks.
.EXAMPLE
    .\diagnose.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"
.EXAMPLE
    .\diagnose.ps1 -Discover
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [switch]$Discover
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

if ($Discover) {
    Write-Host "Discovering IL-2 executables known to Windows AppCompat..." -ForegroundColor Cyan
    $hits = Find-Il2Installation
    if ($hits.Count -eq 0) {
        Write-Host "  none found via AppCompat Layers. Pass -GamePath explicitly." -ForegroundColor Yellow
    } else {
        $hits | ForEach-Object { Write-Host "  $_" }
        if (-not $GamePath -and $hits.Count -eq 1) { $GamePath = $hits[0]; Write-Host "Using discovered path: $GamePath" -ForegroundColor Cyan }
    }
}

if (-not $GamePath) { Write-Error "Provide -GamePath <path to il2fb.exe>, or use -Discover."; exit 2 }
if (-not (Test-ValidExePath $GamePath)) { Write-Error "Not an .exe path: '$GamePath'"; exit 2 }
if (-not (Test-Path $GamePath)) { Write-Warning "File not found on disk: '$GamePath' (checking registry by this exact path anyway)." }

$state = Get-Il2LayerState -ExePath $GamePath
$problem = Get-ProblemLayerName

Write-Host ""
Write-Host "IL-2 1946 AppCompat diagnosis" -ForegroundColor Cyan
Write-Host "Executable : $GamePath"
Write-Host "Problem layer looked for: $problem"
Write-Host ""
foreach ($s in @($state.HKCU, $state.HKLM)) {
    Write-Host ("[{0}] " -f $s.Scope) -NoNewline
    if (-not $s.Present) { Write-Host "no AppCompat Layers entry (absent)" -ForegroundColor DarkGray; continue }
    $flag = if ($s.ContainsProblem) { 'PRESENT' } else { 'not present' }
    $color = if ($s.ContainsProblem) { 'Yellow' } else { 'Green' }
    Write-Host ("value = '{0}' ({1})" -f $s.Data, $s.Type)
    Write-Host ("        {0}: {1}" -f $problem, $flag) -ForegroundColor $color
    if ($s.OtherLayers.Count) { Write-Host ("        other layers (would be preserved): {0}" -f ($s.OtherLayers -join ', ')) }
    if ($s.Prefixes.Count)    { Write-Host ("        control prefixes (preserved): {0}" -f ($s.Prefixes -join ' ')) }
    if ($s.HasUnknown)        { Write-Host "        NOTE: value has an unrecognized token; apply-fix would refuse without -Force." -ForegroundColor Yellow }
}
Write-Host ""
if ($state.ProblemPresent) {
    Write-Host "RESULT: '$problem' IS assigned to IL-2. The fix is applicable." -ForegroundColor Yellow
    Write-Host "Next:   .\apply-fix.ps1 -GamePath `"$GamePath`""
} else {
    Write-Host "RESULT: '$problem' is NOT assigned to IL-2 here. No fix needed." -ForegroundColor Green
}
Write-Host ""
Write-Host "Note: this checks HKCU/HKLM AppCompatFlags\Layers only. Other AppCompat sources" -ForegroundColor DarkGray
Write-Host "      (custom SDB shim databases, the executable's embedded manifest, Group Policy)" -ForegroundColor DarkGray
Write-Host "      are not inspected here." -ForegroundColor DarkGray
exit 0
