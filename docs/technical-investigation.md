# Technical Investigation

How the root cause was found, step by step. Each step lists what was **observed** (evidence) versus what was a **hypothesis** at the time.

## 1. Initial symptom

- **Observation:** IL-2 1946 v4.12.2 took roughly 150–270 seconds to reach the main menu and appeared to freeze near 50% loading, on a fast SSD + modern GPU.
- **Hypothesis:** something is blocking or spinning during startup; not obviously disk- or GPU-bound.

## 2. CPU / disk / GPU profiling

- **Observation:** during the stall a single thread was busy; disk I/O was effectively zero; OpenGL initialised within a few seconds (so the GPU/renderer was not the hold-up). Sampled profiling showed the large majority of CPU time was spent **in the Windows kernel**, not in the game's own user-mode code.
- **Hypothesis:** the game is making a Windows system call, repeatedly, that does expensive work in the kernel.

## 3. Thread-enumeration discovery

- **Observation:** symbolised call stacks showed the hot kernel path was reached via `kernel32!Thread32Next` and `CreateToolhelp32Snapshot` — i.e. **system-wide thread enumeration** (Toolhelp snapshots), plus the kernel work of building and freeing the snapshot buffers.
- **Hypothesis:** IL-2 (or something on its behalf) is enumerating all system threads many times during startup.

## 4. 32-bit Toolhelp benchmark

- **Observation:** a standalone 32-bit program calling the same APIs measured a single full thread enumeration at about **55 ms** with ~8,700 threads present — fast for one call. No abnormal process handle counts were found.
- **Conclusion:** the Windows API itself is not slow; the stall must come from calling it a very large number of times (frequency, not per-call latency).

## 5. System thread-count A/B test

- **Observation:** closing background applications reduced the system thread count from 8,759 to 5,685 and cut startup from 211.8 s to 144.1 s (−35% threads → −32% time).
- **Conclusion:** startup time scales with the number of threads on the whole system — exactly what repeated system-wide enumeration predicts. (This was a controlled test of the *scaling*, not yet proof of the specific caller.)

## 6. Native call-site identification

- **Observation (static + trace):** the game binaries do **not** import any thread-enumeration API and cannot resolve one dynamically. Yet the stacks showed `...il2_corep4.dll -> apphelp.dll -> kernel32!Thread32Next`. Profiling pinned a single dominant game call site in `il2_corep4.dll`; disassembly showed it calls `EnumDisplaySettingsA` and `ChangeDisplaySettingsA(&devmode, CDS_TEST)` — a display-mode enumeration/validation loop. The direct caller of `Thread32Next` was `apphelp.dll!DWM8And16Bit_HookAppWindowProcs`.
- **Conclusion:** the game only asks Windows to validate display modes; the **thread enumeration is injected by `apphelp.dll`** — the Application Compatibility engine — wrapping those display calls.

## 7. AppCompat registry discovery

- **Observation:** the `DWM8And16BitMitigation` compatibility layer was assigned to `il2fb.exe` in both the per-user (HKCU) and machine (HKLM) `AppCompatFlags\Layers` keys. `apphelp.dll` contains that shim family (`DWM8And16Bit_HookAppWindowProcs`, etc.) and references `CreateToolhelp32Snapshot`.
- **Conclusion:** removing that layer should remove the injected enumeration.

## 8. Shim ON/OFF experiment

- **Observation:** with the layer removed (and the system thread count held essentially constant), startup fell from 142.2 s to 18.4 s (−87%) and the game's CPU time fell from 100,453 ms to 5,375 ms (−95%). The menu rendered correctly. The registry was restored to byte-exact originals afterward.
- **Conclusion:** because the only changed variable was the shim, the shim is confirmed as the cause.

## 9. Root-cause conclusion

The slow startup is caused by the Windows `DWM8And16BitMitigation` compatibility shim intercepting IL-2's display-mode validation calls and performing a full system-wide thread enumeration on each one. Removing only that layer for `il2fb.exe` eliminates the overhead, without modifying the game. See [`root-cause.md`](root-cause.md).

## Evidence vs. hypothesis — honest boundaries

- **Well-supported by direct measurement:** the kernel-bound thread enumeration; the `il2_corep4.dll -> apphelp.dll -> Thread32Next` chain; the display-mode call site; the large ON/OFF effect; scaling with system thread count.
- **Inferred, not exhaustively proven:** the exact number of display-mode calls per startup; that the effect size generalises to other hardware/OS versions. The display-mode count depends on how many modes the GPU driver reports, which varies by system.
- **Out of scope here:** AppCompat sources other than the per-executable `Layers` registry values (custom SDB databases, the EXE's embedded manifest, Group Policy).
