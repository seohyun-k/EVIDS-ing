#!/usr/bin/env bash
# Replay gate test (v2): rebuild EvManager from mounted source, then drive ONE DC
# session through the PROVEN collect_a1.sh machinery (robust broker/csms/ev0/config),
# with EV_REPLAY_PROFILE set so the EV requests the real Zenodo curve. Check whether
# the curve flows into ISO present values (manager.log [A1-REPORT]) and OCPP (csms.log).
set -u
cd /opt/EVIDS-ing/everest-core || exit 9
echo "[gate] install rebuilt EvManager..."
micromamba run -n everest ninja -C build install >/tmp/ninja.log 2>&1 || { echo "[gate] NINJA_FAIL"; tail -20 /tmp/ninja.log; exit 1; }

export EV_REPLAY_PROFILE="${EV_REPLAY_PROFILE:-/replay/corsae_s03_030.csv}"
export EV_REPLAY_DURATION_S="${EV_REPLAY_DURATION_S:-180}"
echo "[gate] replay=$EV_REPLAY_PROFILE dur=$EV_REPLAY_DURATION_S"

# one normal session, no attack, no setpoint randomization (replay overrides targets)
export N_NORMAL=1 N_ATTACK=0 FACTORS="0.80" NORMAL_DERATE_FRAC=0 VARY_SETPOINT=0
cd /opt/EVIDS-ing || exit 9
# IMPORTANT: run under the conda env so python3/mosquitto are on PATH (collect needs them).
micromamba run -n everest bash Attack/A1/collect_a1.sh || echo "[gate] collect returned $?"

R=$(ls -1dt Attack/A1/Attack_data/run_* 2>/dev/null | head -1)
echo "[gate] run dir: $R"
S=$(ls -d "$R"/session_* 2>/dev/null | head -1)
echo "[gate] session: $S"
mkdir -p /replay/out
cp "$S"/manager.log /replay/out/manager.log 2>/dev/null
cp "$S"/csms.log /replay/out/csms.log 2>/dev/null
cp "$S"/mqtt.log /replay/out/mqtt.log 2>/dev/null
echo "[gate] REPLAY load:"; grep -a '\[REPLAY\]' "$S"/manager.log 2>/dev/null | head -2
echo "[gate] DONE"
