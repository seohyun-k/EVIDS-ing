#!/usr/bin/env bash
# Connect our patched EVerest to CitrineOS (SP1) and run ONE normal replay session.
set -u
cd /opt/EVIDS-ing/everest-core || exit 9
echo "[cit] install..."; micromamba run -n everest ninja -C build install >/tmp/ninja.log 2>&1 || { echo NINJA_FAIL; tail -15 /tmp/ninja.log; exit 1; }
D=/opt/EVIDS-ing/everest-core/build/dist
STD="$D/share/everest/modules/OCPP201/component_config/standardized"
# 1) OCPP MeterValues 10s
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
# 2) repoint CSMS url -> CitrineOS ws://citrine:8081  (EVerest appends /cp001)
sed -i 's#ws://localhost:9000#ws://citrine:8081#g' "$STD/InternalCtrlr.json"
echo "[cit] ocppCsmsUrl now: $(grep -o 'ocppCsmsUrl[^,]*' "$STD/InternalCtrlr.json" | head -1)"
# 3) BasicAuthPassword = our registered pw
PW=$(cat /replay/cp001_pw.txt)
micromamba run -n everest python3 - "$STD/SecurityCtrlr.json" "$PW" <<'PY'
import json,sys
p,pw=sys.argv[1],sys.argv[2]; d=json.load(open(p)); n=0
for v in d["properties"].values():
    if isinstance(v,dict) and v.get("variable_name")=="BasicAuthPassword":
        for a in v.get("attributes",[]):
            if a.get("type")=="Actual": a["value"]=pw; n+=1
json.dump(d,open(p,"w"),indent=2); print("[cit] set BasicAuthPassword n=",n)
PY
# 4) session length 180s
CFG="$D/etc/everest/config-sil-dc-ocpp201.yaml"; sed -i 's/iso_wait_for_stop [0-9]*/iso_wait_for_stop 180/' "$CFG"
# 5) one normal replay session (csms_ocpp201.py will run but EVerest talks to CitrineOS)
cd /opt/EVIDS-ing || exit 9
export EV_REPLAY_PROFILE=/replay/segments/corsae_s03_030.csv EV_REPLAY_DURATION_S=180 VARY_SETPOINT=0 NORMAL_DERATE_FRAC=0 N_NORMAL=1 N_ATTACK=0
micromamba run -n everest bash Attack/A1/collect_a1.sh 2>&1 | tail -6
R=$(ls -1dt Attack/A1/Attack_data/run_* | head -1); S=$(ls -d "$R"/session_* | head -1)
echo "[cit] manager OCPP 연결 로그:"; grep -aiE 'ocpp|websocket|csms|BootNotif|connect|8081|Rejected|Accepted|Unauthorized|401' "$S/manager.log" 2>/dev/null | tail -12
echo "[cit] DONE"
