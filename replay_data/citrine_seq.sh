#!/usr/bin/env bash
# Sequential real-time full collection: Corsa (cp001) then Honda (cp002), each at its own
# real duration (scale=1, real-time), single-session so cadence stays ~5-10s (RT05 ok).
set -u
run_one(){ echo "[seq] >>> $1 $2 DUR=$3"; STATION="$1" SEGS="$2" DUR="$3" DSDIR=dataset_rt bash /replay/citrine_run.sh; echo "[seq] <<< $1 done"; }
run_one cp001 full_corsae "${CORSA_T}"
run_one cp002 full_hondae "${HONDA_T}"
echo "[seq] ALL DONE"
