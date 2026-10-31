#!/usr/bin/env bash
# Full real-trace dataset: for each car/segment replay profile, collect one NORMAL
# session (replay only) and one ATTACK session per attack type (replay + A1 forge:
# current / energy / voltage). Sessions are pooled by group under /replay/dataset.
# Env overrides (for dry-run): SEGS, DUR, TARGETS.
set -u
cd /opt/EVIDS-ing/everest-core || exit 9
echo "[rc] install..."; micromamba run -n everest ninja -C build install >/tmp/ninja.log 2>&1 || { echo "[rc] NINJA_FAIL"; tail -20 /tmp/ninja.log; exit 1; }

DUR="${DUR:-480}"
CFG=/opt/EVIDS-ing/everest-core/build/dist/etc/everest/config-sil-dc-ocpp201.yaml
sed -i "s/iso_wait_for_stop [0-9]*/iso_wait_for_stop $DUR/" "$CFG"
echo "[rc] session length iso_wait_for_stop=$DUR ; $(grep -o 'iso_wait_for_stop [0-9]*' "$CFG" | head -1)"

# ninja install resets the OCPP component_config, undoing the image's 10s MeterValues
# interval (back to default 120s -> only ~4 samples per session). Re-apply 10s here so
# each session yields ~40-48 MeterValues for feature extraction.
STD=/opt/EVIDS-ing/everest-core/build/dist/share/everest/modules/OCPP201/component_config/standardized
micromamba run -n everest python3 -c '
import json,sys
std=sys.argv[1]
for fn,var in (("SampledDataCtrlr.json","TxUpdatedInterval"),("AlignedDataCtrlr.json","Interval")):
    p=std+"/"+fn; d=json.load(open(p)); n=0
    for v in d["properties"].values():
        if isinstance(v,dict) and v.get("variable_name")==var:
            for a in v.get("attributes",[]):
                if a.get("type")=="Actual": a["value"]=10; n+=1
    json.dump(d,open(p,"w"),indent=2); print("[rc] set",var,"->10 (",n,")")
' "$STD"

SEGS="${SEGS:-corsae_s03_030 corsae_s30_055 corsae_s55_080 corsae_s80_100 hondae_s15_035 hondae_s35_060 hondae_s60_085 hondae_s85_096}"
TARGETS="${TARGETS:-current energy voltage}"
FR=(0.75 0.80 0.90)
DS=/replay/dataset; mkdir -p "$DS"

cd /opt/EVIDS-ing || exit 9
export EV_REPLAY_DURATION_S="$DUR" VARY_SETPOINT=0 NORMAL_DERATE_FRAC=0

stash() { # $1 = group
  local grp="$1" R S dst n
  R=$(ls -1dt Attack/A1/Attack_data/run_* 2>/dev/null | head -1)
  S=$(ls -d "$R"/session_* 2>/dev/null | head -1)
  [ -z "$S" ] && { echo "[rc] WARN no session for $grp"; return; }
  dst="$DS/$grp"; mkdir -p "$dst"
  n=$(ls -d "$dst"/session_* 2>/dev/null | wc -l | tr -d ' ')
  cp -r "$S" "$dst/session_$(printf %03d "$n")"
}

i=0; total=0
for seg in $SEGS; do
  export EV_REPLAY_PROFILE="/replay/segments/$seg.csv"
  f=${FR[$((i % 3))]}
  echo "[rc] === segment $seg (factor $f) ==="
  unset A1_TARGET A1_ATTACK A1_FACTOR
  N_NORMAL=1 N_ATTACK=0 micromamba run -n everest bash Attack/A1/collect_a1.sh >/tmp/c_normal.log 2>&1
  stash normal; total=$((total+1))
  for tgt in $TARGETS; do
    N_NORMAL=0 N_ATTACK=1 FACTORS="$f" A1_TARGET="$tgt" \
      micromamba run -n everest bash Attack/A1/collect_a1.sh >/tmp/c_$tgt.log 2>&1
    stash "$tgt"; total=$((total+1))
  done
  i=$((i+1))
  echo "[rc] segment $seg done; sessions so far=$total"
done
echo "[rc] ALL DONE total=$total groups=$(ls "$DS")"
for g in "$DS"/*; do echo "  $(basename "$g"): $(ls -d "$g"/session_* 2>/dev/null | wc -l | tr -d ' ') sessions"; done
