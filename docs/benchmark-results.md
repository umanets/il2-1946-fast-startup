# Benchmark Results

All numbers below are from **one** test system. They demonstrate the effect on that machine; they are **not** universal guarantees. Please contribute your own measurements.

## Test system

- Game: IL-2 Sturmovik 1946 **v4.12.2**, OpenGL renderer, 32-bit executable (`il2fb.exe`, runs under WoW64).
- OS: Windows 11 Pro (64-bit).
- GPU: NVIDIA GeForce RTX 5070 Ti.
- Storage: SSD.

## Headline A/B result — shim ON vs OFF

Both runs were performed back-to-back on the same machine, in the same elevated context, with **identical game settings**. The **only** variable changed was the presence of the `DWM8And16BitMitigation` compatibility layer on `il2fb.exe`.

| Metric | Shim **ON** (baseline) | Shim **OFF** | Change |
|---|---:|---:|---:|
| Startup to main menu | 142.2 s | 18.4 s | **−87.1 %** (7.7× faster) |
| IL-2 process CPU time at menu | 100,453 ms | 5,375 ms | **−94.6 %** (18.7× less) |
| Windows threads at launch | 5,633 | 5,742 | +1.9 % (≈ equal) |
| Main menu reached | Yes | Yes | — |
| Menu rendered correctly | Yes | Yes | — |

**Key point:** the system-wide thread count did **not** fall between the two runs (it was slightly *higher* in the fast run), yet startup dropped by 87 % and the game's own CPU work dropped by ~95 %. Because the only thing changed was the shim, the improvement is attributable to removing the shim — not to a lighter system.

## Supporting measurement — startup vs system thread count

Earlier in the investigation, before the shim was identified, startup time was measured against the number of threads running on the whole system (by closing background apps). Fewer system threads → faster startup:

| Metric | Normal load | Reduced load | Change |
|---|---:|---:|---:|
| Windows threads | 8,759 | 5,685 | −35.1 % |
| Startup to main menu | 211.8 s | 144.1 s | −32.0 % |

This is consistent with the root cause: the shim's cost is proportional to how many system threads it has to enumerate on each display call.

## Supporting measurement — the API itself is fast

A standalone 32-bit benchmark of the same Windows APIs (`CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD)` + `Thread32First`/`Next`), **outside** the game, measured a single full thread enumeration at about **55 ms** with ~8,700 threads present. A single call is cheap; the stall comes from the shim repeating it many times during the display-mode loop — frequency, not per-call latency.

## Methodology

- **Completion marker:** "main menu ready" was detected by watching the game window stop being *hung* and become responsive (the UI thread resuming its message loop), not by a CPU drop (CPU stays busy at the menu). The same method was used for every run, so comparisons are apples-to-apples. A screenshot confirmed the menu actually rendered.
- **CPU time** is the IL-2 process's total processor time at the moment the menu became ready. It is the most robust metric here because, unlike wall-clock time, it is not affected by CPU contention from other processes.
- **Registry safety:** the A/B changes were surgical (only the two `il2fb.exe` values), backed up first, and restored to byte-exact originals afterward.

## Limitations

- **n = 1 per condition.** A single run per state; no variance/error bars. The effect size (7.7×) is far larger than any plausible run-to-run noise, but more samples would be better.
- **One machine / one configuration.** Results will differ with GPU/driver (which determines how many display modes are enumerated), Windows version, and how many threads your system runs.
- **Both A/B runs were elevated**, so the shim is cleanly isolated; absolute times may differ slightly from a normal (non-elevated) launch, but the ON-vs-OFF difference is what matters.
- The exact number of display-mode calls the game makes was not directly counted; it is inferred from the profiling and the scaling behaviour.

## Reproducing

1. Measure your current startup time (stopwatch from launch to the main menu).
2. `.\diagnose.ps1 -GamePath "<path>\il2fb.exe"` to confirm the layer is present.
3. `.\apply-fix.ps1 -GamePath "<path>\il2fb.exe"`.
4. Measure again.
5. `.\restore.ps1 -GamePath "<path>\il2fb.exe"` to undo.
6. Please [report your before/after numbers](../.github/ISSUE_TEMPLATE/compatibility-report.yml).
