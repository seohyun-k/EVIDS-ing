#!/usr/bin/env bash
# One command to build the EVerest+A1 image and run collection -> analysis on a
# Mac (or any Docker host). Results land on the host under Attack/A1/Attack_data/.
#
#   ./Attack/A1/macbook/run_all.sh smoke     # fast end-to-end sanity (2 sessions)
#   ./Attack/A1/macbook/run_all.sh           # full run (HANDOFF §7c defaults)
#
# Knobs (env):  N_NORMAL N_ATTACK FACTORS NORMAL_DERATE_FRAC A1_TARGET
#               IMAGE (tag)   PLATFORM (e.g. linux/amd64 to force emulation)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-evids-a1}"
MODE="${1:-collect}"

PLATFORM_ARGS=()
[ -n "${PLATFORM:-}" ] && PLATFORM_ARGS=(--platform "$PLATFORM")

command -v docker >/dev/null || { echo "docker not found — install Docker Desktop or colima (see README)."; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon not running — start Docker Desktop / 'colima start' first."; exit 1; }

echo "== [1/2] building '$IMAGE' =="
echo "   (this compiles everest-core; first build is tens of minutes, then cached)"
docker build "${PLATFORM_ARGS[@]}" --build-arg CACHEBUST="${CACHEBUST:-0}" -t "$IMAGE" "$HERE"

OUT="$HERE/../Attack_data"
mkdir -p "$OUT"

echo "== [2/2] running '$MODE' (creates ev0 via --cap-add=NET_ADMIN) =="
docker run --rm --cap-add=NET_ADMIN "${PLATFORM_ARGS[@]}" \
  -e N_NORMAL="${N_NORMAL:-60}" \
  -e N_ATTACK="${N_ATTACK:-30}" \
  -e FACTORS="${FACTORS:-0.75 0.80 0.90}" \
  -e NORMAL_DERATE_FRAC="${NORMAL_DERATE_FRAC:-0.5}" \
  -e A1_TARGET="${A1_TARGET:-coherent}" \
  -v "$OUT:/opt/EVIDS-ing/Attack/A1/Attack_data" \
  "$IMAGE" "$MODE"

echo
echo "== done. latest results on host: =="
RUN="$(ls -1dt "$OUT"/run_* 2>/dev/null | head -1 || true)"
if [ -n "$RUN" ]; then
  echo "  $RUN"
  [ -f "$RUN/eval_report.txt" ] && { echo "  --- eval_report.txt ---"; cat "$RUN/eval_report.txt"; }
fi
