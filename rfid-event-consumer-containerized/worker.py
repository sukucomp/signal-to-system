"""
Standalone Service Bus -> Table Storage worker for signal-to-system.

Python port of rfid-event-consumer-az-function.cs (RfidEventConsumer),
with the Functions bindings/trigger dropped in favor of an explicit
receive loop. Behavior is ported 1:1 from the C# original:

Storage layout:
  PartitionKey = device_id
  RowKey       = event_id  (device-generated UUID v4)

Idempotency: upsert with replace mode. A retry of the same event_id
overwrites the same row rather than erroring or duplicating — this is
the third layer of idempotency after the device UUID and Service Bus's
own duplicate-detection window.

Error handling (matches the C# original):
  - malformed JSON            -> log and complete the message (drop it)
  - missing event_id/device_id -> log and complete the message (drop it)
  - Table Storage write failure -> re-raise so the message is NOT
    completed; Service Bus redelivers it, and after max delivery count
    it lands in the dead-letter queue for inspection

Config (Service Bus / Table Storage connection info, queue/table names)
is read from environment variables via config.py — see that module for
the required/optional var names. This lets the same image run
unmodified locally and in Azure Container Apps.

Shutdown: SIGTERM (sent by Docker/Container Apps on stop) and SIGINT
(Ctrl+C) both trigger a graceful stop. The receive loop polls in short
bursts rather than blocking forever, so a stop request is picked up
within one poll interval instead of interrupting mid-socket-read.
"""

import json
import logging
import signal
import threading
from datetime import datetime, timezone

from azure.core.exceptions import HttpResponseError, ResourceExistsError
from azure.data.tables import TableClient, UpdateMode
from azure.servicebus import ServiceBusClient

from config import Config

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("rfid-worker")

REQUIRED_FIELDS = ("event_id", "device_id")

# Set by the SIGTERM/SIGINT handler; the receive loop checks this each
# poll and exits cleanly instead of being torn down mid-operation.
_shutdown_event = threading.Event()


def _handle_shutdown_signal(signum, _frame):
    signal_name = signal.Signals(signum).name
    logger.info("received %s, shutting down after current message...", signal_name)
    _shutdown_event.set()


def parse_event(raw_body: bytes) -> dict:
    """Parse the inbound message body. Raises on invalid JSON."""
    return json.loads(raw_body)


def to_entity(event: dict) -> dict:
    """Map a parsed RFID event to a Table Storage entity.

    Mirrors the C# TableEntity construction field-for-field.
    """
    return {
        "PartitionKey": event["device_id"],
        "RowKey": event["event_id"],
        "FirmwareVersion": event.get("firmware_version") or "unknown",
        "Uid": event.get("uid") or "",
        "Valid": bool(event.get("valid", False)),
        "TsDeviceMs": event.get("ts_device_ms", 0),
        "ReceivedAtUtc": event.get("received_at_utc"),
        "ProcessedAtUtc": datetime.now(timezone.utc),
    }


def run():
    config = Config.from_env()

    signal.signal(signal.SIGTERM, _handle_shutdown_signal)
    signal.signal(signal.SIGINT, _handle_shutdown_signal)

    sb_client = ServiceBusClient.from_connection_string(config.servicebus_connection_str)
    table_client = TableClient.from_connection_string(config.table_connection_str, config.table_name)
    try:
        table_client.create_table()
    except ResourceExistsError:
        pass  # table already exists — fine, matches C#'s CreateIfNotExists() behavior

    logger.info("starting receive loop on queue=%s", config.queue_name)

    with sb_client:
        with sb_client.get_queue_receiver(queue_name=config.queue_name) as receiver:
            while not _shutdown_event.is_set():
                # Poll in short bursts (max_wait_time) instead of blocking
                # forever, so a shutdown signal is noticed promptly rather
                # than interrupting the socket read mid-frame.
                messages = receiver.receive_messages(max_message_count=1, max_wait_time=5)
                if not messages:
                    continue  # nothing arrived within the poll window; check shutdown flag again

                msg = messages[0]
                raw_body = b"".join(msg.body)

                try:
                    event = parse_event(raw_body)
                except json.JSONDecodeError as e:
                    logger.error("failed to parse message JSON: %s | body=%r", e, raw_body)
                    receiver.complete_message(msg)  # drop malformed message, don't retry
                    continue

                if not event.get("event_id") or not event.get("device_id"):
                    logger.warning("message missing event_id or device_id; skipping. body=%r", raw_body)
                    receiver.complete_message(msg)  # drop, matches C# behavior
                    continue

                entity = to_entity(event)

                try:
                    # Replace mode: create if absent, overwrite if present.
                    # A retry of the same event_id writes the same row again.
                    table_client.upsert_entity(entity, mode=UpdateMode.REPLACE)
                except HttpResponseError:
                    # Don't complete the message — let Service Bus redeliver.
                    # After max delivery count it goes to the dead-letter queue.
                    logger.exception(
                        "failed to write row for event_id=%s; leaving for redelivery",
                        event["event_id"],
                    )
                    continue

                receiver.complete_message(msg)
                logger.info(
                    "wrote row: device=%s event_id=%s uid=%s valid=%s",
                    event["device_id"], event["event_id"],
                    event.get("uid"), event.get("valid"),
                )

    logger.info("shutdown complete")


if __name__ == "__main__":
    run()
