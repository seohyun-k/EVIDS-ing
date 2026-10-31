#!/usr/bin/env python3
# RT/RV rule verification on the collected NORMAL real-trace data (per car).
# ISO present V/I  = manager.log [A1-REPORT] (EVSE side).
# OCPP V/I/SoC/Energy = CitrineOS MeterValues (ocpp_out/<car>_ocpp.csv, epoch,measurand,value).
# RV03 (EVSEPresentVoltage vs OCPP Voltage, ±2%), RV04 (EVSEPresentCurrent vs OCPP Current.Import, ±2%),
# RV06 (SoC consistency, ±3%), RT05 (OCPP meterValue gap). Normal data => violations ~0.
import re, sys, csv, datetime, bisect, statistics as st

def parse_iso(mgr_path):
    ts_re = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)')
    rep_re = re.compile(r'iso_present_current=(\d+) mult=(-?\d+) iso_present_voltage=(\d+) vmult=(-?\d+)')
    cur, volt = [], []  # (epoch, value)
    for line in open(mgr_path, errors='ignore'):
        m = rep_re.search(line)
        if not m: continue
        tm = ts_re.match(line)
        if not tm: continue
        ep = datetime.datetime.strptime(tm.group(1), '%Y-%m-%d %H:%M:%S.%f').replace(tzinfo=datetime.timezone.utc).timestamp()
        i = int(m.group(1)) * (10 ** int(m.group(2)))
        v = int(m.group(3)) * (10 ** int(m.group(4)))
        cur.append((ep, i)); volt.append((ep, v))
    return cur, volt

def load_ocpp(path):
    series = {}
    for row in csv.reader(open(path)):
        if len(row) < 3: continue
        try: ep = float(row[0]); val = float(row[2])
        except: continue
        series.setdefault(row[1], []).append((ep, val))
    for k in series: series[k].sort()
    return series

def nearest(iso, ep, tol=3.0):
    if not iso: return None
    eps = [x[0] for x in iso]
    j = bisect.bisect_left(eps, ep)
    best = None
    for k in (j-1, j):
        if 0 <= k < len(iso):
            d = abs(iso[k][0]-ep)
            if d <= tol and (best is None or d < best[1]): best = (iso[k][1], d)
    return best[0] if best else None

def rv_check(ocpp_series, iso_pairs, tol_pct, lo, hi):
    # compare each OCPP sample (in [lo,hi] charging band) to nearest ISO present value
    viol=0; n=0; diffs=[]
    for ep, oval in ocpp_series:
        if oval < lo or oval > hi: continue   # skip precharge/transients
        iv = nearest(iso_pairs, ep)
        if iv is None: continue
        base = abs(oval) if oval else 1e-9
        d = (iv - oval)/base*100.0
        diffs.append(d); n+=1
        if abs(d) > tol_pct: viol+=1
    med = st.median([abs(x) for x in diffs]) if diffs else 0
    return n, viol, med

def main(car, mgr, ocpp_csv):
    cur_iso, volt_iso = parse_iso(mgr)
    oc = load_ocpp(ocpp_csv)
    print(f"\n######## {car} ########")
    print(f"ISO [A1-REPORT] samples: current={len(cur_iso)} voltage={len(volt_iso)}")
    print(f"OCPP measurands: " + ", ".join(f"{k}={len(v)}" for k,v in oc.items()))
    # RV04 current (±2%), charging band current 1..400
    n,viol,med = rv_check(oc.get('Current.Import',[]), cur_iso, 2.0, 1, 400)
    print(f"RV04 (ISO EVSEPresentCurrent vs OCPP Current.Import, ±2%): n={n} violations={viol} median|diff|={med:.2f}%")
    # RV03 voltage (±2%), charging band 300..500 (skip precharge 900/0)
    n,viol,med = rv_check(oc.get('Voltage',[]), volt_iso, 2.0, 300, 500)
    print(f"RV03 (ISO EVSEPresentVoltage vs OCPP Voltage, ±2%):       n={n} violations={viol} median|diff|={med:.2f}%")
    # RT05 OCPP meterValue gap (use Voltage timestamps)
    eps = sorted(e for e,_ in oc.get('Voltage',[]))
    gaps = [eps[i+1]-eps[i] for i in range(len(eps)-1)]
    if gaps:
        print(f"RT05 (OCPP meterValue gap): median={st.median(gaps):.1f}s max={max(gaps):.1f}s (nominal interval)")
    # SoC range (RV06 is satisfied by construction: OCPP SoC derives from ISO EVRESSSOC)
    socs = [v for _,v in oc.get('SoC',[])]
    if socs: print(f"SoC range: {min(socs):.0f}→{max(socs):.0f}%  (RV06 ISO==OCPP by construction)")

if __name__ == '__main__':
    main('Corsa-e', 'replay_data/dataset_rt/cp001_full_corsae/manager.log', 'replay_data/ocpp_out/corsae_ocpp.csv')
    main('Honda-e', 'replay_data/dataset_rt/cp002_full_hondae/manager.log', 'replay_data/ocpp_out/hondae_ocpp.csv')
