<p align="center">
  <img src="assets/banner.png" alt="IL-2 1946 — WWII warbird" width="100%">
</p>

# IL-2 1946 Fast Startup Fix

**Fix the extremely slow startup and the "stuck at 50% loading" freeze in IL-2 Sturmovik 1946 on modern Windows — without touching any game files.**

If IL-2 1946 takes **minutes** to reach the main menu and appears to hang around 50% loading — even on a fast SSD and a modern GPU — this project can help. The cause is often a **Windows compatibility setting** (not the game itself), and the fix is a small, fully reversible change to that setting.

> ⚠️ This is a community project and is **not** affiliated with the game's publisher or developers. It changes only a per-application Windows registry compatibility value — never game files. See [Safety](#safety).

---

## Before / After (one tested system)

| | Shim enabled (before) | Shim disabled (after) |
|---|---:|---:|
| Startup to main menu | **142.2 s** | **18.4 s** |

**≈ 7.7× faster startup** on the machine we tested.

> These numbers are from **one** Windows 11 system (see [Compatibility](#compatibility)). Your results will vary with your hardware, display modes and background software. This is **not** a universal guarantee — please [report your own results](.github/ISSUE_TEMPLATE/compatibility-report.yml).

---

## Quick Start

Open **Windows PowerShell**, `cd` into the `scripts` folder, and use your own path to `il2fb.exe`.

```powershell
# 1. Diagnose (read-only — changes nothing)
.\diagnose.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"

# 2. Apply the fix (asks for confirmation; prompts for UAC only if needed)
.\apply-fix.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"

# 3. Restore the original settings at any time
.\restore.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"
```

`diagnose.ps1` never needs administrator rights. `apply-fix.ps1` / `restore.ps1` ask for a normal Windows UAC elevation **only** if a machine-wide (HKLM) value must change.

If PowerShell blocks the scripts, run them for the current session with:
`powershell -ExecutionPolicy Bypass -File .\diagnose.ps1 -GamePath "..."`

> Separate problem — blurry picture or an **unclickable menu** because your Windows scale is above 100%? See **[Bonus fix: Windows scaling](#bonus-fix-blurry-image--unclickable-menu-with-windows-scaling)** (`fix-dpi.ps1`).

---

## How It Works

Windows includes an **Application Compatibility** engine that can apply "shims" (compatibility layers) to old programs so they keep working on new Windows versions. One such layer, **`DWM8And16BitMitigation`**, helps very old games that use 8-bit/16-bit colour under the Desktop Window Manager.

IL-2 1946 is a 2000s-era game, so Windows (or a previous compatibility tweak) may assign this layer to `il2fb.exe`. During startup, IL-2 asks Windows to **list and validate display modes**. With the shim active, **each** of those display calls makes Windows **enumerate every thread running on your whole system**. On a modern PC with thousands of threads, doing that over and over turns a sub-second step into **minutes**.

Removing just the `DWM8And16BitMitigation` layer stops that behaviour, so the display-mode step becomes fast again. The game binary, its DLLs and its data are never modified. See [`docs/root-cause.md`](docs/root-cause.md) for the full technical chain.

---

## Bonus fix: blurry image / unclickable menu with Windows scaling

Separate from the startup problem: IL-2 1946 is **DPI-unaware**, so if your **Windows display scale is above 100%** (Settings → System → Display → Scale, e.g. 125–200%), Windows bitmap-stretches the game. The picture turns blurry and, in fullscreen, the **main-menu mouse can mis-map so buttons don't respond**.

`fix-dpi.ps1` sets the per-user **`HIGHDPIAWARE`** compatibility layer — the same as *Properties → Compatibility → "Change high DPI settings" → "Override high DPI scaling behavior" → "Scaling performed by: **Application**"* — so the game renders at native resolution. **HKCU only — no administrator needed.**

```powershell
# Apply (reversible, no admin)
.\fix-dpi.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe"

# Undo
.\fix-dpi.ps1 -GamePath "C:\Games\IL-2 1946\il2fb.exe" -Restore
```

Afterwards the menu/UI looks **smaller** (true native pixels) but **sharp and clickable**. This is independent of the startup fix — use either or both; it preserves any other compatibility flags and keeps its own backup. Verified on one 150%-scaled 4K system.

---

## Safety

- ✅ **No game files are modified** — no EXE, no DLL, no `.SFS` archives, no game resources, no `conf.ini`.
- ✅ **No DLL replacement, no JVM replacement, no SFS repacking, no mods.**
- ✅ Only a **per-executable Windows registry compatibility value** is changed, for the exact path you pass.
- ✅ Only the `DWM8And16BitMitigation` token is removed. Any **other** compatibility flags and control prefixes you have are **preserved**.
- ✅ The Windows AppCompat engine is **never** disabled globally.
- ✅ The exact original values are **backed up to a local file before any change**, and `restore.ps1` puts them back precisely (including the value type and any `$` control prefix). A durable backup means you can restore even if the fix is interrupted.

Registry edits still carry inherent risk. Back up / create a system restore point if you wish, and use `restore.ps1` (or the manual steps in [`docs/troubleshooting.md`](docs/troubleshooting.md)) to undo.

---

## Compatibility

**Verified on one system:**

- IL-2 Sturmovik 1946 **v4.12.2**
- Windows 11 Pro
- NVIDIA GeForce RTX 5070 Ti
- OpenGL renderer

**Not yet verified:** other IL-2 versions, other Windows versions, other GPUs/renderers, modpacks. The fix targets a general Windows mechanism, so it may help elsewhere — but that is untested. Please contribute a [compatibility report](.github/ISSUE_TEMPLATE/compatibility-report.yml).

---

## Technical Investigation

This fix came out of a measured investigation. The write-ups:

- [`docs/root-cause.md`](docs/root-cause.md) — the display-mode → compatibility-shim → thread-enumeration chain.
- [`docs/benchmark-results.md`](docs/benchmark-results.md) — measured results, method and limitations.
- [`docs/technical-investigation.md`](docs/technical-investigation.md) — how the root cause was found, step by step.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — fixing common problems and undoing the change.

---

## Contributing

Help us learn where this does and doesn't help:

- Open a **[compatibility report](.github/ISSUE_TEMPLATE/compatibility-report.yml)** with your IL-2 version, Windows version, GPU, and before/after startup times.
- PRs welcome. Please keep the safety guarantees above, and run the offline tests (`tests/`) before submitting.

---

## Disclaimer

Community-made, **unofficial** project provided "as is" under the [MIT License](LICENSE). Not affiliated with, endorsed by, or supported by the original game's publisher or developers. "IL-2 Sturmovik" and related names are trademarks of their respective owners. You are responsible for any changes you make to your own system.
