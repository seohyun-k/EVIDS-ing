#!/usr/bin/env python3
"""A1 feature extraction: raw session logs -> per-session feature table.

Turns each collected session (mqtt.log + csms.log + manager.log + meta.json,
produced by Attack/A1/collect_a1.sh) into one row of scope-tagged features so the
ISO-only / OCPP-only / concat / cross comparison and the count-only ablation can
be run identically across scopes (see evaluate.py).

Column-name convention encodes the observation scope:
    iso_*    ISO 15118 channel only   (EVSEPresentCurrent / EVSEPresentVoltage)
    ocpp_*   OCPP channel only        (MeterValues Current.Import / Voltage)
    cross_*  ISO <-> OCPP consistency (RV04 current +-2%, RV03 voltage +-2%)
    cnt_*    message counts only      (count-only ablation)
Plus: session_id, label (0/1, from meta.json), factor, target.

PARSING CONTRACT (verify these against a real capture before trusting numbers):
  * ISO present current/voltage are read, in order of preference, from
    (a) the SECC "[A1-ATTACK] ISO present_current spoof: X -> Y" lines in
        manager.log  (Y = forged value that is actually sent to the EV), and
    (b) numeric fields named EVSEPresentCurrent / evse_present_current /
        present_current / present_voltage in JSON payloads on iso15118 topics in
        mqtt.log.
  * OCPP metered values are read from csms.log sampledValue entries whose
    measurand is Current.Import / Voltage (OCPP 2.0.1 MeterValues).
  * True (unforged) current/voltage are read from powermeter topics in mqtt.log.
The regexes are deliberately permissive; if your EVerest build labels fields
differently, adjust ISO_CUR_KEYS / OCPP_MEASURANDS below. Run with --self-test to
validate the whole extract->evaluate pipeline on synthetic data with a known
schema (no testbed required).
"""
import argparse, json, os, re, sys, glob, math

ISO_CUR_KEYS = ("EVSEPresentCurrent", "evse_present_current", "present_current")
ISO_VOLT_KEYS = ("EVSEPresentVoltage", "evse_present_voltage", "present_voltage")
OCPP_MEASURANDS = {"current": ("Current.Import", "Current"), "voltage": ("Voltage",)}

NUM = r"-?\d+(?:\.\d+)?"
# Matches the actual SECC spoof log line, e.g.
#   [A1-ATTACK] ISO present_current: 170 -> 136 (k=0.8000, mult=-1)
# groups: (field, real_before, emitted_after, multiplier?). The emitted value is
# what the EV receives; multiplier (ISO 15118 PhysicalValue) scales it to amps so
# it is comparable to the OCPP MeterValues (already in amps).
SPOOF_RE = re.compile(r"\[A1-ATTACK\] ISO (present_current|present_voltage): "
                      rf"({NUM}) -> ({NUM})(?:[^)]*?mult=(-?\d+))?")

# [A1-REPORT] iso_present_current=<value> mult=<m> : emitted UNCONDITIONALLY on every
# CurrentDemandRes (both normal and attack), carrying the present current actually
# reported to the EV (forged under attack). This is the single, symmetric observation
# source for ISO present current -> no source-asymmetry / message-count confound.
REPORT_RE = re.compile(r"\[A1-REPORT\] iso_present_current=(" + NUM + r") mult=(-?\d+)")


def _stats(xs):
    xs = [float(x) for x in xs if x is not None]
    if not xs:
        return dict(mean=0.0, std=0.0, min=0.0, max=0.0, slope=0.0, n=0)
    n = len(xs)
    mean = sum(xs) / n
    var = sum((x - mean) ** 2 for x in xs) / n
    # slope via simple least squares over sample index
    if n > 1:
        xbar = (n - 1) / 2.0
        sxy = sum((i - xbar) * (xs[i] - mean) for i in range(n))
        sxx = sum((i - xbar) ** 2 for i in range(n))
        slope = sxy / sxx if sxx else 0.0
    else:
        slope = 0.0
    return dict(mean=mean, std=math.sqrt(var), min=min(xs), max=max(xs), slope=slope, n=n)


def _find_numbers_for_keys(text, keys):
    """Extract numeric values that follow any of the given keys in JSON-ish text."""
    vals = []
    for k in keys:
        for m in re.finditer(rf'"{re.escape(k)}"\s*:\s*({NUM})', text):
            vals.append(float(m.group(1)))
        # nested {"Value": X, "Multiplier": M} form
        for m in re.finditer(rf'"{re.escape(k)}"\s*:\s*\{{[^}}]*?"Value"\s*:\s*({NUM})'
                             rf'[^}}]*?"Multiplier"\s*:\s*({NUM})', text):
            vals.append(float(m.group(1)) * (10 ** float(m.group(2))))
    return vals


def _emitted(after, mult):
    """Emitted ISO value scaled to amps/volts: after * 10^mult (mult optional)."""
    return float(after) * (10 ** int(mult)) if mult not in (None, "") else float(after)


def parse_iso(mqtt_text, manager_text):
    # ISO present CURRENT: read from the unconditional [A1-REPORT] telemetry, which the
    # SECC emits on EVERY CurrentDemandRes for both normal and attack sessions and which
    # carries the value ACTUALLY reported to the EV (forged under attack). Reading both
    # classes from this one source keeps the cadence/count identical and only the value
    # differs -> the ISO<->OCPP gap is the sole attack signal (no source/count leakage).
    # Legacy captures without [A1-REPORT] fall back to the mqtt-bus present current.
    cur = [float(v) * (10 ** int(m)) for (v, m) in REPORT_RE.findall(manager_text)]
    if not cur:
        cur = _find_numbers_for_keys(mqtt_text, ISO_CUR_KEYS)
    # ISO present VOLTAGE: genuine in both classes (the current-under-report attack does
    # not forge it), so the mqtt bus value is a symmetric source for normal and attack.
    volt = _find_numbers_for_keys(mqtt_text, ISO_VOLT_KEYS)
    return cur, volt


def parse_ocpp(csms_text):
    """OCPP MeterValues sampledValue by measurand. Handles the common shape
    {"value":"X","measurand":"Current.Import",...} in either key order."""
    def by_measurand(names):
        out = []
        for nm in names:
            out += [float(x) for x in re.findall(
                rf'"value"\s*:\s*"?({NUM})"?[^}}]*?"measurand"\s*:\s*"{re.escape(nm)}"', csms_text)]
            out += [float(x) for x in re.findall(
                rf'"measurand"\s*:\s*"{re.escape(nm)}"[^}}]*?"value"\s*:\s*"?({NUM})"?', csms_text)]
        return out
    cur = by_measurand(OCPP_MEASURANDS["current"])
    volt = by_measurand(OCPP_MEASURANDS["voltage"])
    return cur, volt


def parse_powermeter(mqtt_text):
    cur = _find_numbers_for_keys(mqtt_text, ("current_A", "current", "amperes"))
    volt = _find_numbers_for_keys(mqtt_text, ("voltage_V", "voltage", "volts"))
    return cur, volt


def _steady(xs, drop_frac=0.2):
    """Drop the initial ramp-up region (RV rules only apply at steady state)."""
    if len(xs) < 5:
        return xs
    k = int(len(xs) * drop_frac)
    return xs[k:]


def cross_consistency(iso_vals, ocpp_vals, tol_pct):
    """Pair ISO vs OCPP samples over the overlapping steady-state window and
    compute RV-style consistency stats. Pairing is by index over the shorter
    steady series (both channels sample ~1 Hz); adequate for a constant-factor
    forgery. Returns diff_pct_median, violation_rate, ratio_mean, n_checks."""
    a, b = _steady(iso_vals), _steady(ocpp_vals)
    n = min(len(a), len(b))
    if n == 0:
        return dict(diff_pct_median=0.0, violation_rate=0.0, ratio_mean=1.0, n_checks=0)
    pct = []
    viol = 0
    ratios = []
    for i in range(n):
        base = abs(b[i]) if b[i] else 1e-9
        p = (a[i] - b[i]) / base * 100.0
        pct.append(p)
        ratios.append((a[i] / b[i]) if b[i] else 1.0)
        if abs(p) > tol_pct:
            viol += 1
    pct.sort()
    med = pct[len(pct) // 2]
    return dict(diff_pct_median=med, violation_rate=viol / n,
                ratio_mean=sum(ratios) / n, n_checks=n)


def features_for_session(sdir):
    meta = json.load(open(os.path.join(sdir, "meta.json")))
    mqtt = _read(os.path.join(sdir, "mqtt.log"))
    csms = _read(os.path.join(sdir, "csms.log"))
    mgr = _read(os.path.join(sdir, "manager.log"))

    iso_cur, iso_volt = parse_iso(mqtt, mgr)
    ocpp_cur, ocpp_volt = parse_ocpp(csms)
    pm_cur, pm_volt = parse_powermeter(mqtt)
    # OCPP is the trusted metered channel; fall back to powermeter if OCPP empty
    ref_cur = ocpp_cur or pm_cur
    ref_volt = ocpp_volt or pm_volt

    row = dict(session_id=meta.get("session_id", os.path.basename(sdir)),
               label=int(meta.get("label", 0)),
               factor=float(meta.get("a1_factor", 1.0)),
               target=meta.get("a1_target", "present_current"))

    for name, xs in (("current", iso_cur), ("voltage", iso_volt)):
        for k, v in _stats(_steady(xs)).items():
            row[f"iso_{name}_{k}"] = v
    for name, xs in (("current", ref_cur), ("voltage", ref_volt)):
        for k, v in _stats(_steady(xs)).items():
            row[f"ocpp_{name}_{k}"] = v

    cc_i = cross_consistency(iso_cur, ref_cur, tol_pct=2.0)   # RV04
    for k, v in cc_i.items():
        row[f"cross_rv04_{k}"] = v
    cc_v = cross_consistency(iso_volt, ref_volt, tol_pct=2.0)  # RV03
    for k, v in cc_v.items():
        row[f"cross_rv03_{k}"] = v

    # count-only ablation features (structural message volume)
    row["cnt_iso_current"] = len(iso_cur)
    row["cnt_iso_voltage"] = len(iso_volt)
    row["cnt_ocpp_current"] = len(ocpp_cur)
    row["cnt_ocpp_voltage"] = len(ocpp_volt)
    row["cnt_powermeter"] = len(pm_cur)
    return row


def _read(p):
    try:
        return open(p, errors="replace").read()
    except OSError:
        return ""


def iter_sessions(root):
    for meta in sorted(glob.glob(os.path.join(root, "**", "meta.json"), recursive=True)):
        yield os.path.dirname(meta)


def write_csv(rows, out):
    if not rows:
        print("[extract] no sessions found", file=sys.stderr)
        return
    cols = list(rows[0].keys())
    for r in rows:
        for c in r:
            if c not in cols:
                cols.append(c)
    import csv
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in cols})
    print(f"[extract] wrote {len(rows)} rows x {len(cols)} cols -> {out}")


def self_test(tmp):
    """Synthesize normal + attack sessions with a known schema and run the full
    extract pipeline, so evaluate.py can be validated with no testbed."""
    import random
    random.seed(1)
    os.makedirs(tmp, exist_ok=True)
    def mk(idx, attack, factor):
        sdir = os.path.join(tmp, f"session_{idx:04d}_{'attack' if attack else 'normal'}")
        os.makedirs(sdir, exist_ok=True)
        # CRUCIAL design requirement: normal sessions span a RANGE of charge
        # setpoints, so a forged value lands INSIDE the normal ISO marginal. If
        # every normal session charged at one fixed current, ISO-only would
        # trivially separate the forged value (the paper's ceiling effect) and
        # cross would look unnecessary. Randomizing the per-session setpoint is
        # what makes single-channel detection blind in principle. See collect_a1.sh
        # VARY_SETPOINT and Attack/A1/README.md.
        base = random.uniform(10.0, 32.0)          # per-session DC charge current
        true_cur = [base + random.gauss(0, 0.2) for _ in range(30)]
        true_volt = [400 + random.gauss(0, 1.0) for _ in range(30)]
        iso_cur = [c * (factor if attack else 1.0) for c in true_cur]
        # OCPP meters the TRUE current (power meter untouched by the spoof)
        mqtt = "\n".join(f'everest/iso {{"EVSEPresentCurrent":{c:.3f},"EVSEPresentVoltage":{v:.2f}}}'
                         for c, v in zip(iso_cur, true_volt))
        mqtt += "\n" + "\n".join(f'everest/powermeter {{"current":{c:.3f},"voltage":{v:.2f}}}'
                                 for c, v in zip(true_cur, true_volt))
        csms = "\n".join(f'MeterValues: {{"value":"{c:.3f}","measurand":"Current.Import"}} '
                         f'{{"value":"{v:.2f}","measurand":"Voltage"}}'
                         for c, v in zip(true_cur, true_volt))
        open(os.path.join(sdir, "mqtt.log"), "w").write(mqtt)
        open(os.path.join(sdir, "csms.log"), "w").write(csms)
        open(os.path.join(sdir, "manager.log"), "w").write("Charging session finished\n")
        json.dump(dict(session_id=os.path.basename(sdir), label=int(attack),
                       a1_attack=int(attack), a1_factor=factor,
                       a1_target="present_current"),
                  open(os.path.join(sdir, "meta.json"), "w"))
    i = 0
    for _ in range(30):
        mk(i, 0, 1.0); i += 1
    for _ in range(15):
        mk(i, 1, 0.80); i += 1   # coherent under-report: ISO scaled by k<1, OCPP true
    return tmp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", help="root dir containing session_*/meta.json")
    ap.add_argument("--out", default="Attack/A1/analysis/features.csv")
    ap.add_argument("--self-test", action="store_true",
                    help="synthesize sessions and extract (no testbed needed)")
    args = ap.parse_args()

    root = args.sessions
    if args.self_test:
        root = self_test(os.path.join(os.path.dirname(args.out) or ".", "_selftest_sessions"))
        args.out = os.path.join(os.path.dirname(args.out) or ".", "features_selftest.csv")
    if not root:
        ap.error("provide --sessions DIR or --self-test")

    rows = [features_for_session(s) for s in iter_sessions(root)]
    write_csv(rows, args.out)


if __name__ == "__main__":
    main()
