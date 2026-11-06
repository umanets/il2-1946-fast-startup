# Root Cause

## Summary

IL-2 1946's slow startup on modern Windows is caused by a **Windows Application Compatibility shim**, `DWM8And16BitMitigation`, assigned to `il2fb.exe` — **not** by the game's code, the JVM, the GPU, or disk speed. The shim converts the game's ordinary display-mode queries into repeated, system-wide **thread enumerations**, whose cost grows with the number of threads running on the whole PC.

## The chain, end to end

1. **The game lists display modes at startup.**
   During video setup, IL-2's native engine (`il2_corep4.dll`) runs a loop that enumerates and validates display modes using two documented Win32 APIs:
   - `EnumDisplaySettingsA(NULL, iMode, &devmode)` — iterate available modes.
   - `ChangeDisplaySettingsA(&devmode, CDS_TEST)` — **validate** a mode. `CDS_TEST` only *tests* whether the mode could be set; it does **not** actually change your resolution (so there is no screen flicker).

   This is normal, historically cheap behaviour. A single dominant call site in the engine drives it.

2. **A compatibility shim intercepts those calls.**
   Because `il2fb.exe` has the `DWM8And16BitMitigation` layer assigned, the Windows AppCompat engine (`apphelp.dll`) hooks those display APIs. Its handler calls an internal routine, `DWM8And16Bit_HookAppWindowProcs`, whose job is to (re)install hooks on the application's window procedures so it can mitigate 8-bit/16-bit colour under the Desktop Window Manager.

3. **To do that, the shim enumerates every thread on the system.**
   `DWM8And16Bit_HookAppWindowProcs` calls `CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD)` and walks it with `Thread32First` / `Thread32Next`, filtering to the game's own threads. `CreateToolhelp32Snapshot` with `TH32CS_SNAPTHREAD` takes a snapshot of **all threads on the entire machine**, then the walk visits each one.

4. **This happens on every display call, and the system has thousands of threads.**
   The game makes the display call many times during startup (once per mode it enumerates/validates). Each call triggers a full system-wide thread snapshot + walk. On a 2000s-era Windows PC that was trivial (a few hundred threads total); on a modern Windows 11 PC with **thousands** of threads, each enumeration is far more expensive, and doing it repeatedly turns a sub-second step into **minutes**.

### Observed call chain (from CPU profiling)

```
il2_corep4.dll  (display-mode validation call site, "+0xFD092")
   -> apphelp.dll ! DWM8And16Bit_HookAppWindowProcs      (the compatibility shim)
      -> kernel32.dll ! Thread32Next  /  CreateToolhelp32Snapshot
         -> ntoskrnl.exe              (kernel builds + walks the system-wide snapshot)
```

During the stall, the large majority of CPU time is spent **in the Windows kernel** building and walking these snapshots — not in the game's own code.

## Why common "fixes" don't help

- **SSD / faster GPU:** the work is CPU/kernel-bound thread enumeration, not disk or GPU. There is essentially no disk I/O during the stall, and the GPU/OpenGL initialise quickly.
- **Resolution / fullscreen changes:** they don't change how many display modes get validated or how many system threads exist.
- **Replacing the JVM / using a different IL-2 build:** the game's Java/JVM layer is not where the time goes; the cost is in the Windows shim's thread enumeration.

## Why removing the shim works

Removing only the `DWM8And16BitMitigation` layer means the display-mode APIs are **no longer intercepted**, so they return in microseconds as they always did. The display-mode loop finishes almost instantly, and the startup stall disappears. Nothing about the game changes — only the Windows compatibility setting for that one executable.

## Scope and caveats

- The thread-enumeration cost **scales with the number of threads running on your whole system**, so machines with lots of background software are hit hardest.
- This analysis reflects one tested configuration. The mechanism is general Windows behaviour, but the magnitude of the effect will differ per machine.
- The AppCompat `Layers` registry entry is the source identified here. Other AppCompat mechanisms exist (custom SDB shim databases, the executable's embedded manifest, Group Policy); this project inspects and edits only the per-executable `Layers` values.
