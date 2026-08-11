import asyncio
import logging
import websockets
from datetime import datetime, timezone
from ocpp.routing import on
from ocpp.v201 import ChargePoint as cp
from ocpp.v201 import call_result
from ocpp.v201.enums import (
    RegistrationStatusEnumType,
    AuthorizationStatusEnumType,
    TransactionEventEnumType,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [CSMS] %(message)s")


class ChargePoint(cp):

    @on("BootNotification")
    async def on_boot_notification(self, charging_station, reason, **kwargs):
        logging.info(f"BootNotification: model={charging_station.get('model','?')}, reason={reason}")
        return call_result.BootNotification(
            current_time=datetime.now(timezone.utc).isoformat(),
            interval=300,
            status=RegistrationStatusEnumType.accepted,
        )

    @on("Heartbeat")
    async def on_heartbeat(self, **kwargs):
        return call_result.Heartbeat(current_time=datetime.now(timezone.utc).isoformat())

    @on("StatusNotification")
    async def on_status_notification(self, timestamp, connector_status, evse_id, connector_id, **kwargs):
        logging.info(f"StatusNotification: evse={evse_id} connector={connector_id} status={connector_status}")
        return call_result.StatusNotification()

    @on("TransactionEvent")
    async def on_transaction_event(self, event_type, timestamp, trigger_reason, seq_no, transaction_info, **kwargs):
        logging.info(f"TransactionEvent: type={event_type} trigger={trigger_reason}")
        result = call_result.TransactionEvent()
        if event_type == TransactionEventEnumType.started:
            result.id_token_info = {"status": AuthorizationStatusEnumType.accepted}
        return result

    @on("Authorize")
    async def on_authorize(self, id_token, **kwargs):
        logging.info(f"Authorize: {id_token}")
        return call_result.Authorize(
            id_token_info={"status": AuthorizationStatusEnumType.accepted}
        )

    @on("NotifyReport")
    async def on_notify_report(self, request_id, generated_at, seq_no, **kwargs):
        return call_result.NotifyReport()

    @on("NotifyChargingLimit")
    async def on_notify_charging_limit(self, charging_limit, **kwargs):
        return call_result.NotifyChargingLimit()

    @on("MeterValues")
    async def on_meter_values(self, evse_id, meter_value, **kwargs):
        logging.info(f"MeterValues: evse={evse_id}")
        return call_result.MeterValues()

    @on("SecurityEventNotification")
    async def on_security_event(self, type, timestamp, **kwargs):
        return call_result.SecurityEventNotification()

    @on("LogStatusNotification")
    async def on_log_status(self, status, **kwargs):
        return call_result.LogStatusNotification()

    @on("FirmwareStatusNotification")
    async def on_firmware_status(self, status, **kwargs):
        return call_result.FirmwareStatusNotification()

    @on("Get15118EVCertificate")
    async def on_get_15118_ev_cert(self, iso15118_schema_version, action, exi_request, **kwargs):
        logging.info(f"Get15118EVCertificate: action={action}")
        return call_result.Get15118EVCertificate(status="Accepted", exi_response="")

    @on("NotifyEVChargingNeeds")
    async def on_notify_ev_charging_needs(self, evse_id, charging_needs, **kwargs):
        logging.info(f"NotifyEVChargingNeeds: evse={evse_id}")
        return call_result.NotifyEVChargingNeeds(status="Accepted")

    @on("GetCertificateStatus")
    async def on_get_certificate_status(self, ocsp_request_data, **kwargs):
        logging.info("GetCertificateStatus 요청 수신 — Good 응답")
        return call_result.GetCertificateStatus(status="Accepted")

    @on("SignCertificate")
    async def on_sign_certificate(self, csr, **kwargs):
        return call_result.SignCertificate(status="Accepted")

    @on("GetInstalledCertificateIds")
    async def on_get_installed_cert_ids(self, certificate_type, **kwargs):
        return call_result.GetInstalledCertificateIds(status="Accepted")


async def on_connect(websocket):
    cp_id = websocket.request.path.strip("/")
    logging.info(f"충전기 연결: {cp_id}")
    charge_point = ChargePoint(cp_id, websocket)
    await charge_point.start()


async def main():
    logging.info("OCPP 2.0.1 CSMS 시작 - ws://0.0.0.0:9000")
    async with websockets.serve(
        on_connect,
        "0.0.0.0",
        9000,
        subprotocols=["ocpp2.0.1"],
        ping_interval=None,
    ):
        logging.info("CSMS 대기 중 (Ctrl+C로 종료)")
        await asyncio.Future()


asyncio.run(main())
