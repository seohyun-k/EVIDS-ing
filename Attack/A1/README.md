# A1 — Cross-protocol boundary attack (in-band present-value spoofing)

A1 is redesigned to be the paper's **existence proof**: a concrete attack that is
*individually valid on every single channel* yet is **detectable only by
ISO 15118 ↔ OCPP cross-consistency**. If a single-channel detector cannot flag
it *in principle*, then cross-protocol observation is not a "conditional
improvement" — it is a **necessary condition** for this class.

## Why the previous A1 did not prove necessity

The manuscript's A1 had two independent defects, each fatal to the claim:

1. **Additive MQTT injector (`a1_mqtt_inject.py`) → count confound.**
   It *re-published* a forged value on the same topic instead of *replacing* the
   original, so attack sessions carry structurally more messages. A count-only
   feature ablation reproduced F1 = 1.000 down to 5 % intensity — the model was
   detecting *the act of injection*, not the value inconsistency. The A1 claim
   had to be re-scoped to "detect an unauthorized injection event."

2. **The old in-band C++ patch (`*_current-spoofing.patch`) was out of range.**
   It set `EVSEPresentCurrent.Value *= 8` and `EVSEMaximumCurrentLimit → 250 A`.
   `×8` and a fixed 250 A limit are wildly outside the normal operating band, so
   an ISO-only anomaly detector catches them trivially → cross observation looks
   unnecessary. Low-intensity re-runs then hit a ceiling effect at n = 15.

The fix is the **intersection** of the two approaches' good halves.

## The design

`patches/A1_present-value-spoofing.patch` rewrites the **outgoing** ISO 15118
`EVSEPresentCurrent` / `EVSEPresentVoltage` inside the SECC
(`modules/EVSE/EvseV2G/iso_server.cpp`, DIN mirror in `din_server.cpp`), at the
moment the response is copied into the message the EV receives. It has three
properties that together make A1 a valid existence proof:

| Property | Mechanism | Kills which objection |
|---|---|---|
| **In-band replace** (no extra messages) | edits `res->EVSEPresentCurrent` in place; power meter + internal control untouched | count / injection-artifact confound |
| **Within-range value** | small multiplicative factor near 1.0 (default `A1_FACTOR=1.10`, i.e. +10 %) | "single channel already sees it out of range" |
| **Breaks only cross-consistency** | ISO reports forged value; OCPP `MeterValues` still reports the *true* metered value → RV04 (current, ±2 %) / RV03 (voltage, ±2 %) violated | attributes detection to cross-protocol correspondence, not magnitude |

Because the power meter is never touched, ISO and OCPP disagree while **each
value is individually a perfectly normal charging current/voltage**. ISO-only and
OCPP-only detectors are blind to it by construction; only the cross scope
(RV03/RV04 consistency features) can separate attack from normal. That is the
existence proof.

### Mandatory collection design: randomize the normal setpoint

The patch alone is **not sufficient**. If every normal session charges at one
fixed current (e.g. the config default `dc_target_current: 20`), a forged 22 A is
trivially separable by an ISO-only detector — the paper's ceiling effect recurs
and cross observation looks unnecessary. The forged ISO value must land **inside
the normal ISO marginal**, so `collect_a1.sh` randomizes `dc_target_current`
(and voltage) per session over an **identical range for normal and attack**
(`VARY_SETPOINT=1`, `SETPOINT_MIN/MAX`, default 10–32 A) by deriving a per-session
config from `config-sil-dc-ocpp201.yaml` (`ev_manager_1.config_module`).

Validation on synthetic data with this design (`evaluate.py --self-test`) gives
the intended signature — the existence proof in miniature:

```
scope        model    Prec  Recall    F1  AUROC
ISO-only     RF      0.535   0.489  0.510  0.642   <- near chance (blind in principle)
OCPP-only    RF      0.356   0.333  0.342  0.550   <- near chance
concat       RF      0.546   0.489  0.515  0.644   <- both channels, still weak
cross        RF      1.000   1.000  1.000  1.000   <- only correspondence separates it
count-only   RF      0.000   0.000  0.000  0.500   <- no injection/count confound
```

### Intensity sweep (the key experimental axis)

The forgery factor is the independent variable. It should stay **inside** the
normal operating band and be swept *just across* the RV tolerance:

- `A1_FACTOR=1.03` — near the RV04 ±2 % edge (hardest; expect ISO-only blind, cross marginal)
- `A1_FACTOR=1.10` — default, clearly beyond tolerance but a normal 22 A vs 20 A
- `A1_FACTOR=1.20` — upper end still plausible

The claim to establish: as the factor shrinks toward the tolerance edge,
**ISO-only F1 collapses toward chance while cross F1 stays high** — and, unlike
the old A1, the **count-only ablation now fails** (message counts are identical),
so the surviving signal is genuinely the value inconsistency.

## Runtime parameters (env vars, read once at first CurrentDemand)

| Var | Default | Meaning |
|---|---|---|
| `A1_ATTACK` | unset (off) | `1`/`true`/`yes` enables the spoof |
| `A1_TARGET` | `present_current` | `present_current` \| `present_voltage` \| `both` |
| `A1_FACTOR` | `1.0` (no-op) | multiplicative offset applied to the reported mantissa |

No rebuild is needed to change intensity/target — the SECC binary reads the env
at runtime. Build the patched SECC once, then sweep by exporting env vars per
session (see `collect_a1.sh`).

## Build & run

```bash
# 1. apply the attack patch onto a clean everest-core checkout
cd everest-core
git apply -p1 ../Attack/A1/patches/A1_present-value-spoofing.patch
# 2. build EVerest as usual (produces build/dist)
# 3. collect a labelled dataset (normal + attack sessions, intensity sweep)
cd ..
A1_FACTOR=1.10 A1_TARGET=present_current ./Attack/A1/collect_a1.sh
# 4. features + scope comparison (ISO-only / OCPP-only / concat / cross + count-only ablation)
python3 Attack/A1/analysis/extract_features.py --sessions Attack/A1/Attack_data --out Attack/A1/analysis/features.csv
python3 Attack/A1/analysis/evaluate.py --features Attack/A1/analysis/features.csv
```

## Labelling discipline (unchanged from the paper)

Ground truth comes **only** from the injection log written at collection time
(`meta.json` per session: whether the spoof was enabled, the factor/target, and
the CurrentDemand window). Detector/rule verdicts are never used as labels — that
would let the model learn "copy the rule" and make the evaluation vacuous.
