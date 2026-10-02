# A1 (ISO 15118 value manipulation) — cross-necessity boundary map

ISO-side (SECC / `iso_server.cpp`) static value forgery, in-place substitution.
Question: **when does detection *require* the cross-protocol (ISO↔OCPP) view, and
when can a single channel already catch it?** All runs: EVerest SIL
`config-sil-dc-ocpp201`, 180s charge, MeterValues 10s, device ev0, derate-matched
normal/attack, StratifiedKFold K=5×3 seeds, `[A1-REPORT]` symmetric telemetry.

## Result (AUROC, best model per scope)

| Attack (ISO forgery)            | ISO-only | OCPP-only | cross | Verdict                       |
|---------------------------------|:--------:|:---------:|:-----:|-------------------------------|
| **present_current** under-report|   low    |   low     | **1.00** | **cross-only** ✓            |
| **cumulative-energy** under-rep.|  ~0.43   |  ~0.41    | **0.95–1.00** | **cross-only** ✓ (billing, n=43) |
| **present_voltage** under-report| **1.00** |  ~0.50    | 1.00  | single-channel (ISO) — boundary |
| **power-preserving** I↕V        |    —     |    —      |   —   | physically impossible (precharge) |

(voltage: n=31, 16 normal / 15 attack; ISO-only RF Prec/Rec/F1/AUROC = 1.00 across
every factor 0.75/0.80/0.90; OCPP-only ≈ random 0.25–0.58. energy: n=43, 22/21;
cross LogReg AUROC 0.947 / RF 1.00, single channels all ~random — the linear model
also solving it rules out small-n tree overfit.)

## Why — the cross-necessity condition

Cross is necessary **iff the forged ISO observable is individually plausible** on
its own channel. Two ways that holds:

- **(a) forged value overlaps the normal distribution.** `present_current` tracks
  the EV's setpoint, so it legitimately spans a wide range; a scaled-down current
  sits inside that range and looks normal to ISO-only. Only the time-aligned
  ISO↔OCPP comparison (RV04) exposes the divergence. → cross-only.
- **(b) single-channel observables stay truthful.** Cumulative-energy
  (`MeterInfo.MeterReading`) forgery leaves `present_current`/`present_voltage`
  truthful; neither channel alone sees anything wrong, but the ISO-vs-OCPP energy
  *ratio* breaks. → cross-only (this is the billing-fraud attack).

Voltage satisfies **neither**: `present_voltage` is pinned at the battery voltage
by the PreCharge phase, so in normal operation it is a flat constant
(measured **iso_voltage_mean = 400.0 V, std = 0.0**). Any forged-low value
(326.6 V) falls off that constant and is self-evidently anomalous on the ISO
channel alone → **ISO-only already 1.00, cross adds nothing.** This is the
boundary case that proves cross-necessity is *conditional and physically grounded*,
not a universal property of ISO forgery.

Power-preserving redistribution (lower I, raise V to hold P=V·I) is impossible:
precharge caps `present_voltage` at the battery voltage with no headroom, so the
voltage leg cannot move up (confirmed 3 ways incl. SDPFailedError when max_voltage
is capped).

**SoC** (`DC_EVStatus.EVRESSSOC` → OCPP `SoC` measurand) is likewise *not*
cross-only, for two independent reasons verified in the logs: (1) it is
**single-sourced** — the value originates at the EV and is relayed to both
channels identically (ISO `dc_ev_ress_soc=30.0`, OCPP `measurand:SoC value=30.0`),
so a SECC-side forgery moves both channels together and cross sees no divergence;
and (2) it is **constant** in the SIL (30.0 throughout), so even a single-channel
forgery would be a flat-constant anomaly like voltage. SoC fails condition (a)
*and* (b), same as voltage.

## Completeness

This exhausts the ISO-forgeable DC telemetry quantities: current, voltage, energy,
power, SoC. Only the two that are **both variable (overlapping) and
independently sourced on the two channels** — `present_current`
(EVSE-reported-to-EV vs power-module-measured) and cumulative `MeterReading`
(EVSE meter vs power-module-integrated) — are cross-only. Voltage and SoC are
pinned/single-sourced constants (single-channel detectable), and power reduces to
current (V pinned). So the characterization is complete, not a sample.

## Measured evidence (voltage run)

```
iso_voltage_mean     normal=400.0  attack=326.6   (std normal=0.0)
ocpp_voltage_mean    normal=363.2  attack=363.1   (truthful both)
cross_rv03_violation_rate  normal=0.1  attack=1.0
cross_rv03_diff_pct_median normal=0.0  attack=-18.3%
```

## Takeaway for the paper

The reviewer's concern (A1 single-channel detectability was an MQTT re-injection
artifact) is answered by the in-place-substitution result: with the forged value
flowing on the real bus, **current and energy forgeries are detectable only by the
cross view**, and voltage is a clean boundary that shows *why* — detection follows
the physics of each quantity, not the measurement plumbing.
