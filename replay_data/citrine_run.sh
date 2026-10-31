#!/usr/bin/env bash
# RUN-ONLY (no compile): patches are baked into the image (evids-a1-replay). Configure
# OCPP (CitrineOS url, SP1 password/identity, MeterValues 10s, session length) then run
# the replay session(s). Low RAM -> safe to run several in parallel (distinct STATION).
set -u
D=/opt/EVIDS-ing/everest-core/build/dist
STD="$D/share/everest/modules/OCPP201/component_config/standardized"
micromamba run -n everest python3 -c '
import json,sys
std=sys.argv[1]
for fn,var in (("SampledDataCtrlr.json","TxUpdatedInterval"),("AlignedDataCtrlr.json","Interval")):
    p=std+"/"+fn; d=json.load(open(p))
    for v in d["properties"].values():
        if isinstance(v,dict) and v.get("variable_name")==var:
            for a in v.get("attributes",[]):
                if a.get("type")=="Actual": a["value"]=10
    json.dump(d,open(p,"w"),indent=2)
' "$STD"
sed -i 's#ws://localhost:9000#ws://citrine:8081#g' "$STD/InternalCtrlr.json"
STATION="${STATION:-cp001}"
PW=$(cat "/replay/${STATION}_pw.txt")
micromamba run -n everest python3 - "$STD/SecurityCtrlr.json" "$PW" "$STATION" <<'PY'
import json,sys
p,pw,ident=sys.argv[1],sys.argv[2],sys.argv[3]; d=json.load(open(p))
for v in d["properties"].values():
    if isinstance(v,dict) and v.get("variable_name")=="BasicAuthPassword":
        for a in v.get("attributes",[]):
            if a.get("type")=="Actual": a["value"]=pw
    if isinstance(v,dict) and v.get("variable_name")=="Identity":
        for a in v.get("attributes",[]):
            if a.get("type")=="Actual": a["value"]=ident
json.dump(d,open(p,"w"),indent=2)
PY
echo "[run] station=$STATION"
DUR="${DUR:-480}"
CFG="$D/etc/everest/config-sil-dc-ocpp201.yaml"; sed -i "s/iso_wait_for_stop [0-9]*/iso_wait_for_stop $DUR/" "$CFG"
SEGS="${SEGS:-full_corsae}"
DS="/replay/${DSDIR:-dataset_rt}"; mkdir -p "$DS"
cd /opt/EVIDS-ing || exit 9
# SESSION_TIMEOUT caps each session; for real-time replay it must exceed DUR so the
# session isn't cut at the 260s default. Give DUR + 5min buffer.
export SESSION_TIMEOUT=$(( DUR + 300 ))
export EV_REPLAY_DURATION_S="$DUR" VARY_SETPOINT=0 NORMAL_DERATE_FRAC=0 N_NORMAL=1 N_ATTACK=0
echo "[run] SESSION_TIMEOUT=$SESSION_TIMEOUT DUR=$DUR"
idx=0; : > "$DS/sessions_${STATION}.tsv"
for seg in $SEGS; do
  export EV_REPLAY_PROFILE="/replay/segments/$seg.csv"
  t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  micromamba run -n everest bash Attack/A1/collect_a1.sh >"/tmp/run_$seg.log" 2>&1
  t1=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  R=$(ls -1dt Attack/A1/Attack_data/run_* 2>/dev/null | head -1); S=$(ls -d "$R"/session_* 2>/dev/null | head -1)
  out="$DS/${STATION}_${seg}"; mkdir -p "$out"
  cp "$S/manager.log" "$out/manager.log" 2>/dev/null; cp "$S/meta.json" "$out/meta.json" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$STATION" "$seg" "$t0" "$t1" >> "$DS/sessions_${STATION}.tsv"
  rep=$(grep -ac 'iso_present_voltage' "$S/manager.log" 2>/dev/null)
  echo "[run] $STATION $seg done (A1-REPORT=$rep) [$t0~$t1]"
  idx=$((idx+1))
done
echo "[run] DONE station=$STATION"
