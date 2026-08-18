#!/usr/bin/env bash
# Single-session test with new params (session 180s, TxUpdatedInterval 10s).
# Verifies MeterValues>=5, selected_protocol=ISO15118-2-2013, CurrentDemand loop.
set -u
DIST=/workspace/EV-IDS/everest-core/build/dist
CSMS=/workspace/EV-IDS/everest-core/csms_ocpp201.py
CFG=config-sil-dc-ocpp201
D=/root/data
MQTT=$D/test_mqtt.log
MGR=$D/test_manager.log
CS=$D/test_csms.log
mkdir -p "$D"; : > "$MQTT"; : > "$MGR"; : > "$CS"

cleanup(){ pkill -f 'build/dist/bin/manager' 2>/dev/null; pkill -f 'libexec/everest/modules' 2>/dev/null; pkill -f csms_ocpp201 2>/dev/null; pkill -f 'mosquitto_sub -h localhost' 2>/dev/null; }
trap cleanup EXIT
cleanup; sleep 1

# ev0
ip link show ev0 >/dev/null 2>&1 || { ip link add ev0 type dummy; ip link set ev0 up; }
echo "[test] ev0: $(ip -6 addr show dev ev0 scope link 2>/dev/null | awk '/inet6/{print $2}')"

# broker dual-stack
if ! mosquitto_pub -h 127.0.0.1 -t t/p -m x >/dev/null 2>&1; then
  cat > /root/.mosquitto.conf <<EOF
listener 1883 0.0.0.0
allow_anonymous true
listener 1883 ::1
allow_anonymous true
EOF
  mosquitto -c /root/.mosquitto.conf -d; sleep 1
fi
echo "[test] broker: $(mosquitto_pub -h 127.0.0.1 -t t/p -m x >/dev/null 2>&1 && echo up || echo DOWN)"

# csms
nohup python3 "$CSMS" >> "$CS" 2>&1 & sleep 2
echo "[test] csms started"

# capture everest/#
timeout 220 mosquitto_sub -h localhost -t 'everest/#' -v >> "$MQTT" 2>&1 &
CAP=$!

# manager (one session, 180s charge)
( cd "$DIST" && ./bin/manager --prefix "$DIST" --config "$CFG" ) >> "$MGR" 2>&1 &
MPID=$!
echo "[test] manager pid=$MPID; running one 180s-charge session (~210s)..."

# wait until session completes (unplug) or capture ends
t=0
while kill -0 "$CAP" 2>/dev/null; do
  if grep -qiE 'Car unplugged|unplug|V2G session stopped|Charging session finished' "$MGR" 2>/dev/null; then
    echo "[test] session finished at ~${t}s"; sleep 5; break
  fi
  kill -0 "$MPID" 2>/dev/null || { echo "[test] manager exited early at ${t}s"; break; }
  sleep 5; t=$((t+5))
done
cleanup; sleep 1

echo "======================= TEST RESULT ======================="
iso2=$(grep -c "ISO15118-2-2013" "$MQTT")
cd=$(grep -ci currentdemand "$MQTT")
iso=$(grep -ci iso15118 "$MQTT"); ocpp=$(grep -ci ocpp "$MQTT"); pm=$(grep -ci powermeter "$MQTT")
# MeterValues: OCPP2.0.1 carries sampled data in TransactionEvent(meterValue) + MeterValues msgs
mv_arrays=$(grep -oc '"meterValue"' "$CS"); [ -z "$mv_arrays" ] && mv_arrays=$(grep -c 'meterValue' "$CS")
tx_started=$(grep -c 'TransactionEvent: type=Started' "$CS")
tx_updated=$(grep -c 'TransactionEvent: type=Updated' "$CS")
tx_ended=$(grep -c 'TransactionEvent: type=Ended' "$CS")
mv_msgs=$(grep -c 'MeterValues:' "$CS")
echo "selected_protocol ISO15118-2-2013 lines : $iso2"
echo "CurrentDemand (mqtt)                    : $cd"
echo "channels mqtt iso15118/ocpp/powermeter  : $iso / $ocpp / $pm"
echo "--- OCPP (csms) ---"
echo "TransactionEvent Started/Updated/Ended  : $tx_started / $tx_updated / $tx_ended"
echo "MeterValues messages (MeterValuesReq)   : $mv_msgs"
echo "meterValue payloads total (Tx+MV)       : $mv_arrays"
echo "selected_protocol values seen:"; grep -i selected_protocol "$MQTT" | grep -oE '"data":"[^"]+"' | sort | uniq -c
# criterion: MeterValues per session >= 5  (count meterValue-bearing OCPP messages)
mv_total=$(( tx_updated + mv_msgs ))
echo "MeterValue-bearing OCPP msgs (updated+MV): $mv_total"
if [ "$mv_total" -ge 5 ] && [ "$iso2" -ge 1 ] && [ "$cd" -ge 1 ]; then
  echo "RESULT: PASS (MeterValues>=5, ISO15118-2-2013, CurrentDemand ok)"
else
  echo "RESULT: FAIL (mv_total=$mv_total iso2=$iso2 cd=$cd)"
fi
echo "==========================================================="
