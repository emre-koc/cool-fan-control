# Cool Fan Control

Free, open-source (MIT) fan control & temperature monitoring for **Apple Silicon Macs (M1–M5)** — macOS 14+.

- 🌡️ **Smart temperature curve** with hysteresis — no fan hunting
- 🌀 Manual per-fan RPM · Quiet · Max · named presets (Gaming, Turbo, …)
- 🔥 Live CPU/GPU temps + animated fans in the menu bar
- 🔋 **Battery care:** while charging, fans kick in at **33 °C** (mid) and step up above **35 °C** to keep the battery cool
- 🛡️ **Throttle guard:** CPU ≥ **90 °C** → fans max, before throttling
- 🔄 Always restores Apple's automatic fan control on quit
- 🚫 No telemetry, no subscriptions, no paywall. MIT licensed.

Requires a root helper (installed on first launch) because macOS restricts SMC access to root.

**Install:** download the DMG from Releases, or `brew install --cask alpico/tap/cool-fan-control`.

**Dev:** see `AGENTS.md`, `Docs/architecture.md`, and `Docs/implementation-plan.md`.
