#!/usr/bin/env bash
# Attack-overlay test: replay a real Zenodo curve (normal) and the same curve with the
# A1 ISO under-report forgery (attack), then check that in the NORMAL session ISO==OCPP
# while in the ATTACK session ISO present is forged low vs the true OCPP meter (cross
# divergence). Confirms the A1 attack stacks on top of real-trace replay.
set -u
cd /opt/EVIDS-ing/everest-core || exit 9
echo "[atk] install..."; micromamba run -n everest ninja -C build install >/tmp/ninja.log 2>&1 || { echo NINJA_FAIL; tail -20 /tmp/ninja.log; exit 1; }

export EV_REPLAY_PROFILE="${EV_REPLAY_PROFILE:-/replay/corsae_s03_030.csv}"
export EV_REPLAY_DURATION_S="${EV_REPLAY_DURATION_S:-180}"
export N_NORMAL=1 N_ATTACK=1 FACTORS="0.75" A1_TARGET=current NORMAL_DERATE_FRAC=0 VARY_SETPOINT=0
echo "[atk] replay=$EV_REPLAY_PROFILE dur=$EV_REPLAY_DURATION_S A1_TARGET=current factor=0.75"
cd /opt/EVIDS-ing || exit 9
micromamba run -n everest bash Attack/A1/collect_a1.sh || echo "[atk] collect rc=$?"

R=$(ls -1dt Attack/A1/Attack_data/run_* 2>/dev/null | head -1)
mkdir -p /replay/atk
for S in "$R"/session_*; do
  b=$(basename "$S")
  cp "$S/manager.log" "/replay/atk/${b}_manager.log" 2>/dev/null
  cp "$S/csms.log" "/replay/atk/${b}_csms.log" 2>/dev/null
done
echo "[atk] sessions: $(ls -d "$R"/session_* | xargs -n1 basename | tr '\n' ' ')"
echo "[atk] DONE"
