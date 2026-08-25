# Hardware Verification Checklist

## Mac mini M1 — Milestone 0

- [x] AppleSMC service opens.
- [x] Fan count discovered (`FNum=1`).
- [x] Fan min/max read (`1700…4499 RPM`).
- [x] Actual RPM read (`F0Ac`, `flt ` type).
- [x] Manual mode enabled as root.
- [x] Target RPM written (`2500`).
- [x] Actual fan response observed (`2443 RPM`).
- [x] Script exit restored automatic control (`F0Md=0`).
- [x] Independent post-exit read confirmed baseline return (~1712 RPM).

## MacBook Pro M1 Max — pending

- [ ] Discover `FNum` and both fans' min/max/actual RPM.
- [ ] Enumerate and classify CPU/GPU temperature sensors.
- [ ] Read charging status and charge percentage via IOPowerSources.
- [ ] Enumerate and identify the battery temperature sensor.
- [ ] Test fan 0 manual target and restore.
- [ ] Test fan 1 manual target and restore.
- [ ] Validate 33 °C mid / 35 °C high battery tiers using temporarily lowered test thresholds.
- [ ] Validate CPU 90 °C guard using a safely lowered test threshold before any real thermal stress test.

## Release safety checks — pending

- [ ] Quit restores all fans to auto within one second.
- [ ] `kill -9` app triggers helper watchdog restore within 30 seconds.
- [ ] Helper crash/restart begins in auto mode.
- [ ] RPM target always clamps to each fan's hardware limits.
- [ ] Missing/invalid sensor readings never trigger unsafe writes.
- [ ] Sleep/wake re-reads limits and safely re-applies the selected mode.
