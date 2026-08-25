# Cool Fan Control

macOS menu-bar fan control + temperature & battery monitoring for **Apple Silicon (M1–M5) only**.
Open source (MIT), free, no telemetry. Distributed outside the App Store: Developer ID–signed,
notarized, Homebrew cask.

## Scope (V1)
- Menu bar app, macOS 14+.
- Modes: Auto / Smart (temp curve + hysteresis) / Manual (per-fan RPM) / Quiet / Max.
- Named presets (Gaming, Turbo, …) persisted as JSON.
- Battery (laptops only): charging status via IOPowerSources; battery temp via SMC (`TB0T`/`BT0C`);
  two-tier cooling rule while charging: **> 33 °C → mid fans, > 35 °C → high fans** (default max),
  2 °C hysteresis, release 31/33 °C. Desktops (no battery) hide battery UI.
- CPU throttle guard: **CPU ≥ 90 °C → fans max** (release < 88 °C), overrides any mode.
- Effective target = `max(mode, cpuGuard, batteryRule)`, clamped to fan limits.
- Always restores Apple's automatic fan control on quit / crash (heartbeat watchdog in helper).

## Architecture
- SwiftUI app + root LaunchDaemon helper (`com.alpico.coolfancontrol.helper`), XPC over Mach service.
- The helper is the **only** process that writes SMC. Correctly formed SMC reads work unprivileged
  on macOS 26, while writes require root. Reads remain centralized in the helper for atomic snapshots.
- Apple Silicon fan RPM keys are `flt ` (IEEE754) on the tested M1 Mac mini, not legacy `fpe2`;
  the codec must inspect each key's reported type rather than assuming Intel-era formats.
- Helper installed via `SMAppService.daemon`; app must run from /Applications.
- All testable logic lives in `Core/` (SwiftPM package; engine/rules are pure, no IOKit).

## Non-goals
- No Intel support (Apple Silicon only; Intel guard at launch).
- No App Store build (unsandboxed hardware access by design).
- No charging/power control — battery cooling is fans-only.
- No telemetry, no network calls.

## Conventions
- Strict TDD: failing test → run → minimal code → pass → commit. Scoped commits.
- Unit tests run without hardware; hardware validation via `scripts/hardware-test.sh` (root) and
  the checklist in `Docs/hardware-verification.md`.
- Implementation plan: `Docs/implementation-plan.md` (master copy at
  `~/.hermes/plans/2026-08-25_103734-mac-fan-control.md`).
