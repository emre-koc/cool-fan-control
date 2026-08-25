# Hardware Notes

## Mac mini M1 baseline — 2026-08-25

**Machine:** Macmini9,1 · Apple M1 · macOS 26.5.2 · one fan · no battery

### AppleSMC protocol findings

- `SMCParamStruct` must be exactly 80 bytes.
- `IOConnectCallStructMethod` selector is always `2` (`kSMCHandleYPCEvent`).
- Operation lives in `data8`: `9` key info, `5` read, `6` write.
- SMC key FourCCs are canonical big-endian numeric values.
- Reads work unprivileged; writes require root.
- Fan RPM keys on this Apple Silicon Mac report `flt ` (native IEEE-754 float), not legacy `fpe2`.

### Read baseline

```text
FNum [ui8 /1] = 1
F0Ac [flt /4] ≈ 1700
F0Mn [flt /4] = 1700
F0Mx [flt /4] = 4499
F0Md [ui8 /1] = 0
F0Tg [flt /4] = 1700
```

The initially assumed temperature keys (`TC0P`, `TCXC`, `TG0P`, `TM0P`, `TH0P`, `TH1P`) are absent on this M1. Milestone 3 must enumerate SMC keys and derive an Apple-Silicon sensor catalog instead of relying only on Intel-era names.

### Root write validation

Command:

```bash
sudo scripts/hardware-test.sh write 2500
```

Observed:

```text
F0Mn=1700 F0Mx=4499 -> F0Tg=2500 (manual mode, auto-restored on exit)
F0Md = written
F0Tg = written
actual:
F0Ac [flt /4] = 2443
F0Md [ui8 /1] = 1
```

This proves real fan control: actual RPM reached 2443 against a 2500 target.

### Automatic-control restoration

After the script exited, an independent unprivileged read showed:

```text
F0Md [ui8 /1] = 0
F0Ac [flt /4] = 1712.33
F0Tg [flt /4] = 1700
F0Mn [flt /4] = 1700
F0Mx [flt /4] = 4499
```

**Result:** PASS — the EXIT trap restored Apple's automatic mode (`F0Md=0`) and the fan returned to its 1700 RPM baseline.

## Pending hardware validation

- M1 Max MacBook Pro: enumerate two fan sets and identify CPU/GPU/battery temperature keys.
- Confirm battery charging status via IOPowerSources.
- Confirm battery temperature key(s), including `TB0T`/`BT0C` fallbacks or discovered alternatives.
- Verify both fans accept independent targets and both restore to automatic mode.
