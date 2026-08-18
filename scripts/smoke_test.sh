#!/usr/bin/env bash
# 30s smoke test: mosquitto -> csms -> manager, check "All modules initialized" + everest/# topics
set -u
DIST=/workspace/everest-core/build/dist
LOGD=/workspace/logs
CSMS=/workspace/everest-core/csms_ocpp201.py
CFG=config-sil-dc-ocpp201           # short form (no .yaml); resolved under $DIST/etc/everest
MGRLOG=$LOGD/smoke_manager.log
CSMSLOG=$LOGD/smoke_csms.log
MQTTLOG=$LOGD/smoke_mqtt.log
mkdir -p "$LOGD"
: > "$MGRLOG"; : > "$CSMSLOG"; : > "$MQTTLOG"

cleanup() {
  echo "[smoke] teardown"
  pkill -f 'build/dist/bin/manager' 2>/dev/null
  pkill -f 'libexec/everest/modules' 2>/dev/null
  kill "${CSMS_PID:-0}" 2>/dev/null
  pkill -f 'csms_ocpp201.py' 2>/dev/null
  pkill -x mosquitto 2>/dev/null
  sleep 1
}
trap cleanup EXIT

echo "[smoke] start $(date '+%F %T')"

# 1) mosquitto broker
cat > /workspace/.mosquitto.conf <<EOF
listener 1883 127.0.0.1
allow_anonymous true
EOF
pkill -x mosquitto 2>/dev/null; sleep 1
mosquitto -c /workspace/.mosquitto.conf -d
sleep 1
if mosquitto_pub -h 127.0.0.1 -p 1883 -t smoke/ping -m hi 2>/dev/null; then
  echo "[smoke] mosquitto 1883: PING OK"
else
  echo "[smoke] mosquitto 1883: PING FAIL"; exit 2
fi

# background MQTT sampler (~6s window starting at t=12s)
( sleep 12; timeout 6 mosquitto_sub -h 127.0.0.1 -p 1883 -t 'everest/#' -v ) > "$MQTTLOG" 2>&1 &

# 2) csms
python3 "$CSMS" > "$CSMSLOG" 2>&1 &
CSMS_PID=$!
echo "[smoke] csms pid=$CSMS_PID"
sleep 2

# 3) manager
cd "$DIST" || exit 3
./bin/manager --prefix "$DIST" --config "$CFG" > "$MGRLOG" 2>&1 &
MGR_PID=$!
echo "[smoke] manager pid=$MGR_PID (prefix=$DIST config=$CFG)"

# 4) poll up to 35s for readiness
READY_AT=""
for i in $(seq 1 35); do
  if grep -qiE "All modules are initialized|Everest up and running|modules are initialized" "$MGRLOG"; then
    READY_AT=$i; break
  fi
  if ! kill -0 "$MGR_PID" 2>/dev/null; then
    echo "[smoke] !! manager exited early at ${i}s"; break
  fi
  sleep 1
done

echo "=================== RESULT ==================="
if [ -n "$READY_AT" ]; then
  echo "[smoke] READY: manager reported initialization at ~${READY_AT}s"
else
  echo "[smoke] NOT READY within 35s"
fi
echo
echo "----- manager log: readiness lines -----"
grep -niE "All modules are initialized|Everest up and running|modules are initialized|ready" "$MGRLOG" | head
echo
echo "----- manager log tail (20) -----"
tail -n 20 "$MGRLOG"
echo
echo "----- manager log: errors/warnings (sample) -----"
grep -niE "error|fatal|exception|failed|traceback" "$MGRLOG" | head -15 || echo "(none)"
echo
echo "----- MQTT sample: distinct topics (head 40) -----"
cut -d' ' -f1 "$MQTTLOG" | sort -u | head -40
echo "total distinct topics: $(cut -d' ' -f1 "$MQTTLOG" | sort -u | wc -l); total lines: $(wc -l < "$MQTTLOG")"
echo
echo "----- MQTT sample: iso15118 / ocpp / powermeter presence -----"
for k in iso15118 ocpp powermeter; do
  n=$(grep -ci "$k" "$MQTTLOG"); echo "  $k : $n msgs"
done
echo
echo "----- csms log tail (12) -----"
tail -n 12 "$CSMSLOG"
echo "=============================================="
echo "[smoke] end $(date '+%F %T')"
