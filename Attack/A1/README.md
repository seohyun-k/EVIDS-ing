# A1 — Cross-protocol boundary attack (coherent ISO under-report)

A1 is the paper's **ISO-side existence proof**: a compromised charging station
under-reports metering to the EV over ISO 15118-2 while the OCPP side (power
meter → CSMS) keeps the true values. Each channel is internally consistent, so
neither ISO-only nor OCPP-only detection can flag it — only an ISO↔OCPP
value cross-check (RV04 for current, an energy-consistency check for the meter
reading) reveals the inconsistency. This is the mirror of the OCPP-side
under-report (A3-MV/SC): same physical quantities, but the **ISO channel** is the
one that lies.

## Why this is genuinely cross-protocol-necessary (and the earlier attacks were not)

The RV01–RV06 attacks in the original design (and the old `×8` present-current
patch) are all catchable by a **single channel**, because each forges only one
side of ISO's request/measurement pair, in the anomalous direction, at a large
magnitude. This attack fixes all three:

| Condition | This attack | Why it matters |
|---|---|---|
| **DOWN direction** | present < target (report *less* than delivered) | `present ≤ target` is normal derating; `present > target` (the old ×1.1–×8 forges) is anomalous → ISO-only catches it |
| **COHERENT** | scale present current **and** cumulative energy by the same `k` (voltage held) | energy = ∫(present·power) stays consistent within ISO; forging only the meter reading (energy-only) breaks this and is caught by the ISO-internal ∫ check |
| **IN-RANGE** | `k` near 1 (default 0.8), setpoints randomized per session | the forged value stays inside the normal per-session distribution, so it is not a magnitude outlier |

Because the power meter is never touched, OCPP MeterValues stay true, and only
the ISO↔OCPP disagreement exposes the attack. Message counts are unchanged (a
pure in-message value rewrite), so there is no injection/count confound.

## Real-world validity

- **Feasible on real hardware.** A compromised station fully controls the
  `EVSEPresentCurrent` and `MeterInfo.MeterReading` it puts in the ISO 15118-2
  `CurrentDemandRes`. An optional ISO meter *signature* does not help: the
  compromised EVSE signs the forged value, so single-channel signature/OCMF
  validation passes — only the cross-check catches it.
- **The ∫ self-check is real, and this attack survives it.** On a real charger,
  the ISO plaintext also carries `EVSEPresentCurrent/Voltage`, so an ISO-only
  detector could integrate present power and compare against `MeterReading`.
  Forging only the meter reading (option "energy") fails this check; the
  **coherent** forge (current + energy by the same `k`) passes it. See the smoke
  test below.
- **Scope caveat (stated in the paper).** The EV's own BMS measures true battery
  current, so the EV could locally notice. The IDS/CSMS does not have that private
  measurement; the threat model scopes detection to the two reported streams at
  the charger boundary.
- **Defense.** The real countermeasure is binding ISO metering to the OCPP report
  under one signed measurement (OCMF + ISO `MeterInfo` signature bound to the
  OCPP-reported value). A cross-protocol IDS is the detection path where that
  binding is not deployed.

## The patch

`patches/A1_iso-coherent-underreport.patch` edits the SECC
(`modules/EVSE/EvseV2G/iso_server.cpp`, inside `handle_iso_current_demand`) to
rewrite the outgoing `res->EVSEPresentCurrent` and `res->MeterInfo.MeterReading`
by factor `k`, downstream of the ISO/OCPP split (control state and power meter
untouched). Applies cleanly to clean `everest-core` (`git apply -p1`).

Runtime config (env, read once):

| Var | Default | Meaning |
|---|---|---|
| `A1_ATTACK` | unset (off) | `1`/`true`/`yes` enables |
| `A1_FACTOR` | `1.0` (no-op) | scale factor `k`; `<1` = under-report (e.g. `0.8`) |
| `A1_TARGET` | `coherent` | `coherent` (current+energy, voltage held) · `current` · `voltage` · `energy` · e.g. `current,energy` |

EVerest does not republish these `res` values on its MQTT bus, so the forged
values are also emitted as `[A1-ATTACK] ISO …` log lines for the collector to
observe (matching `analysis/extract_features.py`).

## Smoke test (runnable without building EVerest)

`analysis/smoke_forge.cpp` replicates the patch's exact forge arithmetic and
checks the attack invariants on a simulated CurrentDemand session:

```bash
g++ -std=c++17 -O2 Attack/A1/analysis/smoke_forge.cpp -o /tmp/a1smoke
A1_ATTACK=1 A1_FACTOR=0.8 /tmp/a1smoke          # coherent → all 6 checks PASS
A1_ATTACK=1 A1_FACTOR=0.8 A1_TARGET=energy /tmp/a1smoke   # meter-only → COHERENT check FAILS (ratio 0.81)
```

The coherent run passes: present 16 A ≤ target 20 A (derating), energy/∫-power
ratio ≈ 1.0 (ISO-internally consistent), voltage held, RV04 gap 20 % > 2 %
(cross catches), OCPP true, message counts unchanged. The energy-only run
demonstrates the ∫-check weakness of a single-field forge (ratio 0.81).

## Scope comparison (ML, synthetic self-test)

`analysis/extract_features.py` (log parsing) and `analysis/evaluate.py` (ISO-only
/ OCPP-only / concat / cross + count-only ablation) reproduce the target
signature on synthetic data with the coherent down-forge:

```
scope        model    F1     AUROC
ISO-only     RF      0.54    0.69     ← near chance (blind in principle)
OCPP-only    RF      0.34    0.55     ← near chance
cross        RF      1.00    1.00     ← only correspondence separates it
count-only   RF      0.00    0.50     ← no injection/count confound
```

```bash
python3 Attack/A1/analysis/evaluate.py --self-test        # no testbed needed
```

## Live collection (on a machine with a built EVerest)

```bash
cd everest-core && git apply -p1 ../Attack/A1/patches/A1_iso-coherent-underreport.patch
# build EVerest (produces build/dist), then:
cd .. && A1_FACTOR=0.8 A1_TARGET=coherent ./Attack/A1/collect_a1.sh
python3 Attack/A1/analysis/extract_features.py --sessions Attack/A1/Attack_data --out Attack/A1/analysis/features.csv
python3 Attack/A1/analysis/evaluate.py --features Attack/A1/analysis/features.csv --by-factor
```

`collect_a1.sh` randomizes `dc_target_current` per session over an identical
range for normal and attack (so the forged value stays inside the normal ISO
marginal), and labels come only from the injection plan (`meta.json`), never
from a detector.
