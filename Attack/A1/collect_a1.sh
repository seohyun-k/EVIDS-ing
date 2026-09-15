#!/usr/bin/env bash
# A1 data collection driver.
#
# Runs a plan of normal + attack charging sessions in the EVerest SIL testbed
# (config-sil-dc-ocpp201) and writes, per session, the raw ISO/OCPP/powermeter
# streams plus a ground-truth injection log (meta.json). The attack is the
# coherent ISO under-report from patches/A1_iso-coherent-underreport.patch and is
# toggled per session purely by exporting env vars (no rebuild between
# intensities). Labels come from the injection plan, never from a detector.
#
# Usage:
#   ./Attack/A1/collect_a1.sh                    # defaults below
#   N_NORMAL=40 N_ATTACK=20 FACTORS="0.75 0.80 0.90" A1_TARGET=coherent \
#       ./Attack/A1/collect_a1.sh
#
# Env knobs:
#   N_NORMAL   normal sessions to collect               (default 20)
#   N_ATTACK   attack sessions PER factor               (default 20)
#   FACTORS    scale factors k (<1 = under-report)      (default "0.80")
#   A1_TARGET  coherent|current|voltage|energy           (default coherent)
#   A1_DIST    EVerest build/dist prefix (auto-detected if unset)
#   CSMS       path to csms_ocpp201.py (auto-detected if unset)
#   CFG        base EVerest config name                  (default config-sil-dc-ocpp201)
#   OUTROOT    output root                               (default Attack/A1/Attack_data)
#   SESSION_TIMEOUT  hard per-session cap in seconds     (default 260)
#   VARY_SETPOINT  1=randomize dc_target_current/voltage per session (default 1)
#   SETPOINT_MIN/MAX  DC target current range in A       (default 10 / 32)
#   NORMAL_DERATE_FRAC  share of NORMAL sessions that legitimately derate
#                       (present<target, label 0)         (default 0.5)
#   DERATE_MIN/MAX  supply cap as fraction of target      (default 0.55 / 0.90)
#
# WHY VARY_SETPOINT MATTERS (do not disable without reason): the forged ISO value
# must land INSIDE the normal ISO current marginal, otherwise an ISO-only detector
# separates it trivially (the paper's ceiling effect) and cross observation looks
# unnecessary. Randomizing the per-session charge setpoint over an identical range
# for normal AND attack sessions is what makes single-channel detection blind in
# principle -- that is the existence proof. See Attack/A1/README.md.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
N_NORMAL="${N_NORMAL:-20}"
N_ATTACK="${N_ATTACK:-20}"
FACTORS="${FACTORS:-0.80}"
A1_TARGET="${A1_TARGET:-coherent}"
CFG="${CFG:-config-sil-dc-ocpp201}"
OUTROOT="${OUTROOT:-$REPO_ROOT/Attack/A1/Attack_data}"
SESSION_TIMEOUT="${SESSION_TIMEOUT:-260}"
VARY_SETPOINT="${VARY_SETPOINT:-1}"
SETPOINT_MIN="${SETPOINT_MIN:-10}"
SETPOINT_MAX="${SETPOINT_MAX:-32}"
# Legitimate derating in NORMAL data (essential for validity): a fraction of
# normal sessions cap the DC supply below the EV target so the charger delivers
# LESS than requested (present < target) — a normal condition — and OCPP meters
# that true lower value (ISO = OCPP). Without this, an ISO-only model separates
# the attack's present<target as an artifact and the existence proof is void.
NORMAL_DERATE_FRAC="${NORMAL_DERATE_FRAC:-0.5}"   # share of normal sessions that derate
DERATE_MIN="${DERATE_MIN:-0.55}"                  # supply cap as fraction of target current
DERATE_MAX="${DERATE_MAX:-0.90}"

# ---- locate build/dist and csms ----
autodetect() { for c in "$@"; do [ -e "$c" ] && { echo "$c"; return 0; }; done; return 1; }
A1_DIST="${A1_DIST:-$(autodetect \
  "$REPO_ROOT/everest-core/build/dist" \
  /workspace/everest-core/build/dist \
  /workspace/EV-IDS/everest-core/build/dist)}"
CSMS="${CSMS:-$(autodetect \
  "$REPO_ROOT/everest-core/csms_ocpp201.py" \
  /workspace/everest-core/csms_ocpp201.py)}"

if [ -z "${A1_DIST:-}" ] || [ ! -x "$A1_DIST/bin/manager" ]; then
  echo "[collect] ERROR: manager not found under A1_DIST='$A1_DIST'." >&2
  echo "          Build the patched everest-core first (see Attack/A1/README.md)." >&2
  exit 3
fi
[ -n "${CSMS:-}" ] || { echo "[collect] ERROR: csms_ocpp201.py not found; set CSMS=." >&2; exit 3; }

RUN_ID="run_$(date '+%Y%m%d_%H%M%S')"
RUNDIR="$OUTROOT/$RUN_ID"
mkdir -p "$RUNDIR"
echo "[collect] run=$RUN_ID dist=$A1_DIST csms=$CSMS cfg=$CFG"
echo "[collect] plan: normal=$N_NORMAL (derate frac=$NORMAL_DERATE_FRAC), attack/factor=$N_ATTACK, factors=[$FACTORS], target=$A1_TARGET"

# ---- broker (kept up across sessions) ----
BROKER_CONF=/tmp/a1_mosquitto.conf
cat > "$BROKER_CONF" <<EOF
listener 1883 0.0.0.0
allow_anonymous true
listener 1883 ::1
allow_anonymous true
EOF
ensure_broker() {
  mosquitto_pub -h 127.0.0.1 -t a1/ping -m x >/dev/null 2>&1 && return 0
  pkill -x mosquitto 2>/dev/null; sleep 1
  mosquitto -c "$BROKER_CONF" -d; sleep 1
  mosquitto_pub -h 127.0.0.1 -t a1/ping -m x >/dev/null 2>&1
}
# ev0 dummy iface (ISO 15118 link-local)
ip link show ev0 >/dev/null 2>&1 || { ip link add ev0 type dummy 2>/dev/null; ip link set ev0 up 2>/dev/null; }

# EVerest resolves --config <name> under $DIST/etc/everest/. Locate the installed
# base config so we can derive per-session copies with a randomized setpoint.
BASE_CFG_FILE="$(autodetect \
  "$A1_DIST/etc/everest/$CFG.yaml" \
  "$REPO_ROOT/everest-core/config/$CFG.yaml")"
ETC_EVEREST="$A1_DIST/etc/everest"

# make_session_config <sid> <target_current> <target_voltage> [supply_cap] -> echoes config NAME
# Overrides dc_target_current/voltage; if supply_cap is given, also caps the DC
# supply's max_current (config_implementation.main.max_current on powersupply_dc)
# so the charger legitimately delivers less than the EV target (derating).
make_session_config() {
  local sid="$1" cur="$2" volt="$3" cap="${4:-}"
  if [ "$VARY_SETPOINT" != "1" ] || [ -z "${BASE_CFG_FILE:-}" ] || [ ! -w "$ETC_EVEREST" ]; then
    [ "$VARY_SETPOINT" = "1" ] && [ -z "${_warned_setpoint:-}" ] && {
      echo "[collect] WARN: VARY_SETPOINT=1 but base config or $ETC_EVEREST not writable;" >&2
      echo "          falling back to fixed setpoint -> ISO-only ceiling effect likely." >&2
      _warned_setpoint=1; }
    echo "$CFG"; return 0
  fi
  local name="config-a1-$sid"
  sed -E "s/^([[:space:]]*dc_target_current:).*/\1 $cur/; s/^([[:space:]]*dc_target_voltage:).*/\1 $volt/" \
      "$BASE_CFG_FILE" \
  | awk -v cap="$cap" '
      { print }
      /^[[:space:]]*module:[[:space:]]*DCSupplySimulator[[:space:]]*$/ && cap != "" {
        print "    config_implementation:"
        print "      main:"
        print "        max_current: " cap
      }' > "$ETC_EVEREST/$name.yaml"
  echo "$name"
}
rand_range() { python3 -c "import random,sys;print(round(random.uniform(float(sys.argv[1]),float(sys.argv[2])),1))" "$1" "$2"; }

kill_session() {
  pkill -f 'build/dist/bin/manager' 2>/dev/null
  pkill -f 'libexec/everest/modules' 2>/dev/null
  pkill -f 'csms_ocpp201' 2>/dev/null
  pkill -f "mosquitto_sub .*everest/#" 2>/dev/null
}
trap 'echo "[collect] teardown"; kill_session; pkill -x mosquitto 2>/dev/null' EXIT

# run_one <sessdir> <attack 0|1> <factor> [derate_frac]
# derate_frac (normal sessions only): if set, cap DC supply to derate_frac*target
# so present < target legitimately (label stays 0 = normal).
run_one() {
  local sdir="$1" attack="$2" factor="$3" derate_frac="${4:-}"
  mkdir -p "$sdir"
  local MQTT="$sdir/mqtt.log" MGR="$sdir/manager.log" CS="$sdir/csms.log"
  : > "$MQTT"; : > "$MGR"; : > "$CS"

  ensure_broker || { echo "[collect] broker down, skipping $sdir"; return 1; }
  kill_session; sleep 1

  # randomized per-session setpoint (identical range for normal & attack)
  local tgt_cur=20 tgt_volt=400 sess_cfg="$CFG"
  if [ "$VARY_SETPOINT" = "1" ]; then
    tgt_cur=$(rand_range "$SETPOINT_MIN" "$SETPOINT_MAX")
    tgt_volt=400
  fi
  # legitimate derating (normal sessions only): cap supply below target
  local supply_cap="" derate=0
  if [ -n "$derate_frac" ]; then
    supply_cap=$(python3 -c "import sys;print(round(float(sys.argv[1])*float(sys.argv[2]),1))" "$tgt_cur" "$derate_frac")
    derate=1
  fi
  sess_cfg=$(make_session_config "$(basename "$sdir")" "$tgt_cur" "$tgt_volt" "$supply_cap")

  local start_epoch; start_epoch=$(date +%s)
  # ground-truth injection log — the ONLY source of labels
  cat > "$sdir/meta.json" <<EOF
{
  "session_id": "$(basename "$sdir")",
  "label": $attack,
  "a1_attack": $attack,
  "a1_factor": $( [ "$attack" = "1" ] && echo "$factor" || echo "1.0" ),
  "a1_target": "$A1_TARGET",
  "config": "$sess_cfg",
  "dc_target_current": $tgt_cur,
  "dc_target_voltage": $tgt_volt,
  "derate_normal": $derate,
  "supply_max_current": $( [ -n "$supply_cap" ] && echo "$supply_cap" || echo "null" ),
  "start_epoch": $start_epoch,
  "note": "label from injection plan, not from any detector"
}
EOF

  # csms (fresh per session)
  nohup python3 "$CSMS" >> "$CS" 2>&1 &
  sleep 2
  # capture everest/# for the whole session
  timeout "$SESSION_TIMEOUT" mosquitto_sub -h localhost -t 'everest/#' -v >> "$MQTT" 2>&1 &
  local CAP=$!

  # manager (one charge session) with attack env applied only for attack runs
  (
    cd "$A1_DIST" || exit 9
    if [ "$attack" = "1" ]; then
      export A1_ATTACK=1 A1_FACTOR="$factor" A1_TARGET="$A1_TARGET"
    else
      unset A1_ATTACK A1_FACTOR A1_TARGET
    fi
    ./bin/manager --prefix "$A1_DIST" --config "$sess_cfg"
  ) >> "$MGR" 2>&1 &
  local MPID=$!

  # wait for session completion (unplug) or capture timeout
  local t=0
  while kill -0 "$CAP" 2>/dev/null; do
    if grep -qiE 'Car unplugged|unplug|V2G session stopped|Charging session finished' "$MGR" 2>/dev/null; then
      sleep 4; break
    fi
    kill -0 "$MPID" 2>/dev/null || { echo "[collect]   manager exited early @ ${t}s ($sdir)"; break; }
    sleep 5; t=$((t+5))
  done
  kill_session; sleep 1

  # finalize meta with end time + quick sanity counts
  local end_epoch iso ocpp pm cd
  end_epoch=$(date +%s)
  iso=$(grep -ci iso15118 "$MQTT"); ocpp=$(grep -ci ocpp "$CS"); pm=$(grep -ci powermeter "$MQTT")
  cd=$(grep -ci currentdemand "$MQTT")
  python3 - "$sdir/meta.json" "$end_epoch" "$iso" "$ocpp" "$pm" "$cd" <<'PY'
import json,sys
p,end,iso,ocpp,pm,cd=sys.argv[1:7]
d=json.load(open(p)); d.update(end_epoch=int(end),
  sanity=dict(iso15118_lines=int(iso),ocpp_lines=int(ocpp),powermeter_lines=int(pm),currentdemand_lines=int(cd)))
json.dump(d,open(p,'w'),indent=2)
PY
  echo "[collect]   done $(basename "$sdir") attack=$attack factor=$factor iso=$iso ocpp=$ocpp pm=$pm cd=$cd"
}

idx=0
# normal sessions — a NORMAL_DERATE_FRAC share of them derate (present<target,
# label still 0) so the attack's present<target is not separable single-channel.
for i in $(seq 1 "$N_NORMAL"); do
  roll=$(python3 -c "import random;print(1 if random.random() < $NORMAL_DERATE_FRAC else 0)")
  if [ "$roll" = "1" ]; then
    frac=$(rand_range "$DERATE_MIN" "$DERATE_MAX")
    printf -v sid "session_%04d_normal_derate" "$idx"
    run_one "$RUNDIR/$sid" 0 1.0 "$frac"
  else
    printf -v sid "session_%04d_normal" "$idx"
    run_one "$RUNDIR/$sid" 0 1.0
  fi
  idx=$((idx+1))
done
# attack sessions per factor
for f in $FACTORS; do
  for i in $(seq 1 "$N_ATTACK"); do
    printf -v sid "session_%04d_attack_f%s" "$idx" "${f/./p}"
    run_one "$RUNDIR/$sid" 1 "$f"
    idx=$((idx+1))
  done
done

echo "[collect] complete: $idx sessions under $RUNDIR"
echo "[collect] next: python3 Attack/A1/analysis/extract_features.py --sessions $RUNDIR --out Attack/A1/analysis/features.csv"
