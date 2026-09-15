#!/usr/bin/env bash
# Container entrypoint: create the dummy interface ISO 15118 SDP needs, then run
# the A1 collection + feature extraction + scope evaluation. All params are env
# overridable (see run_all.sh). `docker run ... shell` drops into bash instead.
set -euo pipefail

IFACE="${IFACE:-ev0}"

# Dummy interface = the whole reason we run in a container. Needs CAP_NET_ADMIN.
if ! ip link show "$IFACE" >/dev/null 2>&1; then
  if ip link add "$IFACE" type dummy && ip link set "$IFACE" up; then
    echo "[entrypoint] created dummy interface '$IFACE' (ISO 15118 SDP loopback)"
  else
    echo "[entrypoint] FATAL: cannot create dummy '$IFACE'." >&2
    echo "             Run the container with:  --cap-add=NET_ADMIN" >&2
    exit 1
  fi
fi
ip link set lo up 2>/dev/null || true

cd /opt/EVIDS-ing
eval "$(micromamba shell hook -s bash)"
micromamba activate everest

# Pin both ISO modules to the dummy and forward collection knobs. Defaults here
# are the full run from HANDOFF §7c; override any with `docker run -e NAME=...`.
export IFACE
export N_NORMAL="${N_NORMAL:-60}"
export N_ATTACK="${N_ATTACK:-30}"
export FACTORS="${FACTORS:-0.75 0.80 0.90}"
export NORMAL_DERATE_FRAC="${NORMAL_DERATE_FRAC:-0.5}"
export A1_TARGET="${A1_TARGET:-coherent}"

case "${1:-collect}" in
  collect)
    echo "[entrypoint] plan: N_NORMAL=$N_NORMAL N_ATTACK=$N_ATTACK FACTORS=[$FACTORS]" \
         "derate=$NORMAL_DERATE_FRAC target=$A1_TARGET iface=$IFACE"
    ./Attack/A1/collect_a1.sh
    RUN="$(ls -1dt Attack/A1/Attack_data/run_* | head -1)"
    echo "[entrypoint] extracting features from $RUN"
    python3 Attack/A1/analysis/extract_features.py --sessions "$RUN" --out "$RUN/features.csv"
    echo "[entrypoint] scope evaluation -> $RUN/eval_report.txt"
    python3 Attack/A1/analysis/evaluate.py --features "$RUN/features.csv" --by-factor \
      | tee "$RUN/eval_report.txt"
    echo "[entrypoint] done. Results under: $RUN"
    ;;
  smoke)
    # 1 normal (forced derate) + 1 attack, fast, to prove the pipeline end-to-end.
    N_NORMAL=1 N_ATTACK=1 NORMAL_DERATE_FRAC=1 FACTORS="0.80" \
      ./Attack/A1/collect_a1.sh
    RUN="$(ls -1dt Attack/A1/Attack_data/run_* | head -1)"
    echo "[entrypoint] smoke run under: $RUN"
    grep -l 'A1-ATTACK' "$RUN"/*/manager.log 2>/dev/null \
      && echo "[entrypoint] A1-ATTACK spoof lines present (attack session active)" \
      || echo "[entrypoint] NOTE: no A1-ATTACK lines yet (check charge reached CurrentDemand)"
    ;;
  shell)
    exec bash
    ;;
  *)
    exec "$@"
    ;;
esac
