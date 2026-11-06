# Troubleshooting

## "Running scripts is disabled on this system" (execution policy)

Run the script for the current session only, without changing your system policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\diagnose.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"
```

## "Access is denied" / permission errors when applying or restoring

- The **machine-wide (HKLM)** value needs administrator rights. `apply-fix.ps1` and `restore.ps1` will ask for a normal Windows **UAC elevation** automatically when an HKLM change is required. Approve the prompt.
- `diagnose.ps1` is read-only and should not need elevation. If reading HKLM fails on a locked-down machine, run it from an elevated PowerShell.
- If you prefer to elevate yourself, start **"Windows PowerShell (Admin)"** first, then run the script.

## The script says the layer is **not present**

Then this particular fix does not apply to your machine — `DWM8And16BitMitigation` is not assigned to your `il2fb.exe`. Your slow startup (if any) may have a different cause. Note that this tool checks only the per-executable `AppCompatFlags\Layers` registry values; other compatibility sources exist (custom shim databases, the executable's manifest, Group Policy) and are **not** inspected here.

## "No backup found" when restoring

`restore.ps1` restores from a backup file that `apply-fix.ps1` writes **before** it changes anything (by default under `%LOCALAPPDATA%\il2-1946-fast-startup\backups`). If no backup exists, either the fix was never applied, or the backup was deleted/relocated.

- If you used a custom `-BackupDir`, pass the same `-BackupDir` to `restore.ps1`.
- If the backup is truly gone, you can restore manually with the original values this fix removes (shown by `diagnose.ps1` before you apply). Typically the original values were:
  - HKCU: `REG_SZ` = `DWM8And16BitMitigation`
  - HKLM: `REG_SZ` = `$ DWM8And16BitMitigation`

  To re-add them (adjust the path; the HKLM line needs an elevated prompt):
  ```
  reg add "HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" /v "C:\Games\IL-2 1946\il2fb.exe" /t REG_SZ /d "DWM8And16BitMitigation" /f
  reg add "HKLM\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" /v "C:\Games\IL-2 1946\il2fb.exe" /t REG_SZ /d "$ DWM8And16BitMitigation" /f /reg:64
  ```
  Your own original values may differ (e.g. extra flags). Only re-add what you actually had.

## "Refusing: ... is unfamiliar" when applying

Your `Layers` value contains a token the tool doesn't recognize. To be safe it refuses rather than guess. The tool only ever removes the exact `DWM8And16BitMitigation` token and keeps everything else verbatim, so if you've checked the value you can override with `-Force`:

```powershell
.\apply-fix.ps1 -GamePath "...\il2fb.exe" -Force
```

## The game still launches slowly after the fix

- Re-run `diagnose.ps1` to confirm the layer is actually gone. If a tool like the **Program Compatibility Assistant** re-added it, it may have come back (see below).
- Remember the fix addresses the `DWM8And16BitMitigation`-shim cause specifically. Other factors (very large skin/mission folders, antivirus scanning, a different compatibility layer, or genuinely heavy content) can also slow startup and are outside this project's scope.

## The game fails to launch or looks wrong after the fix

- The `DWM8And16BitMitigation` layer mitigates 8-bit/16-bit colour. On a 32-bit-colour + OpenGL setup it is normally unnecessary, but if you see colour corruption, a black screen, or other display issues, **restore** immediately:
  ```powershell
  .\restore.ps1 -GamePath "...\il2fb.exe"
  ```
- Then please file a [compatibility report](../.github/ISSUE_TEMPLATE/compatibility-report.yml) describing your renderer and colour depth so others know.

## Still slow because "Run this program in compatibility mode" is enabled

If, on **Properties → Compatibility**, the box **"Run this program in compatibility mode for"** is
checked (Windows XP / Vista / 7 / …), removing `DWM8And16BitMitigation` alone will **not** help —
and it can look like the fix "resets itself".

Reason: an old-Windows compatibility mode is itself a layer (`WINXPSP3`, `WIN7RTM`, `VISTARTM`, …)
stored in the same `Layers` value, and those modes **bundle the same DWM 8/16-bit mitigation**. So
the slow system-wide thread enumeration comes back from the OS mode even after the standalone
`DWM8And16BitMitigation` token is gone. This tool deliberately preserves that OS-mode token (it does
not touch unrelated compatibility settings), so you must turn it off yourself.

Fix: **uncheck "Run this program in compatibility mode"** (Properties → Compatibility). IL-2 4.12 on
Windows 10/11 does not need an old-OS compatibility mode. `diagnose.ps1` / `apply-fix.ps1` now warn
when such a mode is detected.

## Verifying the current state at any time

```powershell
.\diagnose.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"
```
It prints the exact HKCU/HKLM values and whether `DWM8And16BitMitigation` is present — handy for confirming the fix applied, or that a restore put things back.

## Checking the shim hasn't been reassigned

Windows' Program Compatibility Assistant can re-apply a compatibility layer to an old program it thinks misbehaved. If startup becomes slow again later, re-run `diagnose.ps1`; if the layer is back, re-run `apply-fix.ps1`. (This project does not change PCA behaviour.)
