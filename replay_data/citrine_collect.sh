#!/usr/bin/env bash
# Full NORMAL data collection via CitrineOS. For each car/segment replay profile, run one
# normal charging session (EVerest replay -> CitrineOS OCPP 2.0.1). ISO data = manager.log
# [A1-REPORT]; OCPP data lands in CitrineOS Postgres (one transaction per session).
# No attack/forgery. SoC now follows the real curve (iso_server patch).
set -u
cd /opt/EVIDS-ing/everest-core || exit 9
echo "[cc] install..."; micromamba run -n everest ninja -C build install >/tmp/ninja.log 2>&1 || { echo "[cc] NINJA_FAIL"; tail -15 /tmp/ninja.log; exit 1; }
D=/opt/EVIDS-ing/everest-core/build/dist
STD="$D/share/everest/modules/OCPP201/component_config/standardized"
# OCPP MeterValues 10s
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
# CSMS -> CitrineOS + SP1 password
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
echo "[cc] station identity=$STATION"
DUR="${DUR:-480}"
CFG="$D/etc/everest/config-sil-dc-ocpp201.yaml"; sed -i "s/iso_wait_for_stop [0-9]*/iso_wait_for_stop $DUR/" "$CFG"
echo "[cc] session length=$DUR, CSMS=CitrineOS"

SEGS="${SEGS:-corsae_s03_030 corsae_s30_055 corsae_s55_080 corsae_s80_100 hondae_s15_035 hondae_s35_060 hondae_s60_085 hondae_s85_096}"
DS="/replay/${DSDIR:-dataset_citrine}"; mkdir -p "$DS"
cd /opt/EVIDS-ing || exit 9
export EV_REPLAY_DURATION_S="$DUR" VARY_SETPOINT=0 NORMAL_DERATE_FRAC=0 N_NORMAL=1 N_ATTACK=0
idx=0; n_seg=$(echo $SEGS | wc -w | tr -d ' ')
: > "$DS/sessions.tsv"
for seg in $SEGS; do
  export EV_REPLAY_PROFILE="/replay/segments/$seg.csv"
  t_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  micromamba run -n everest bash Attack/A1/collect_a1.sh >"/tmp/cc_$seg.log" 2>&1
  t_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  R=$(ls -1dt Attack/A1/Attack_data/run_* 2>/dev/null | head -1)
  S=$(ls -d "$R"/session_* 2>/dev/null | head -1)
  out="$DS/$(printf %02d "$idx")_${seg}"; mkdir -p "$out"
  cp "$S/manager.log" "$out/manager.log" 2>/dev/null
  cp "$S/meta.json" "$out/meta.json" 2>/dev/null
  printf '%02d\t%s\t%s\t%s\n' "$idx" "$seg" "$t_start" "$t_end" >> "$DS/sessions.tsv"
  rep=$(grep -ac 'iso_present_voltage' "$S/manager.log" 2>/dev/null)
  echo "[cc] $(($idx+1))/$n_seg $seg done (ISO A1-REPORT=$rep)  [$t_start~$t_end]"
  idx=$((idx+1))
done
echo "[cc] ALL DONE ($idx sessions)"
