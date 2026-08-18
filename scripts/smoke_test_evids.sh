#!/usr/bin/env bash
# 30s smoke test: mosquitto -> csms -> manager, check "All modules initialized" + everest/# topics
set -u
DIST=/workspace/EV-IDS/everest-core/build/dist
LOGD=/workspace/logs
CSMS=/workspace/EV-IDS/everest-core/csms_ocpp201.py
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

# ensure dummy ev0 with fe80:: link-local for ISO15118 HLC
if ! ip link show ev0 >/dev/null 2>&1; then
  ip link add ev0 type dummy && ip link set ev0 up
fi
if ip -6 addr show dev ev0 2>/dev/null | grep -q "fe80::"; then
  echo "[smoke] ev0 link-local ready: $(ip -6 addr show dev ev0 scope link | awk '/inet6/{print $2}')"
else
  echo "[smoke] WARNING: ev0 has no fe80:: link-local"
fi

# 1) mosquitto broker
cat > /workspace/.mosquitto.conf <<EOF
listener 1883 0.0.0.0
allow_anonymous true
listener 1883 ::1
allow_anonymous true
max_connections -1
log_dest file /tmp/mosquitto.log
log_type all
EOF
pkill -9 -x mosquitto 2>/dev/null; sleep 1
: > /workspace/logs/mosquitto.log
mosquitto -c /workspace/.mosquitto.conf -d
sleep 1
if mosquitto_pub -h 127.0.0.1 -p 1883 -t smoke/ping -m hi 2>/dev/null; then
  echo "[smoke] mosquitto 1883: PING OK"
else
  echo "[smoke] mosquitto 1883: PING FAIL"; exit 2
fi


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

# sample everest/# while manager is Running (after readiness) - long window to catch charging loop
if kill -0 "$MGR_PID" 2>/dev/null; then
  echo "[smoke] sampling everest/# for 45s while Running (watching for ISO15118 HLC + charging loop)..."
  timeout 45 mosquitto_sub -h 127.0.0.1 -p 1883 -t 'everest/#' -v > "$MQTTLOG" 2>&1
fi
echo
echo "----- ISO15118 HLC checks (manager log) -----"
echo -n "  'No IPv6 link-local' present? : "; grep -c "No IPv6 link-local" "$MGRLOG"
echo "  selected_protocol / ISO15118 negotiation:"; grep -niE "selected_protocol|ISO15118-2|ISO-15118|DIN70121|SLAC matched|slac.*match|V2G.*(start|success|connected)" "$MGRLOG" | grep -viE "No IPv6" | head -12
echo "  evse_manager state (Inoperative/ready/charging):"; grep -niE "Inoperative|Ready to start charging|enter_state|Charging|session_event|PowerReady|WaitingForEnergy" "$MGRLOG" | tail -12
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
echo "----- MQTT sample: series + charging-loop presence -----"
for k in iso15118 ocpp powermeter CurrentDemand EVSEPresentCurrent selected_protocol; do
  n=$(grep -ci "$k" "$MQTTLOG"); echo "  $k : $n msgs"
done
echo "  [selected_protocol topic values:]"; grep -i "selected_protocol" "$MQTTLOG" | head -4
echo
echo "----- csms log tail (12) -----"
tail -n 12 "$CSMSLOG"
echo "=============================================="
echo "[smoke] end $(date '+%F %T')"
