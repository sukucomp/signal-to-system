"""
RFID serial ingestor.

Reads EVENT:{...} lines from a serial-connected microcontroller and prints
parsed events. Validates the fleet-ready schema:

    {
      "event_id":         "<uuid>",        # generated on device, used for idempotency
      "device_id":        "reader-NN",     # which reader produced this event
      "firmware_version": "1.1.0",         # firmware running on the device
      "uid":              "AA BB CC DD",   # RFID card UID, hex space-separated
      "valid":            true | false,    # against the device's local allow-list
      "ts_device_ms":     <int>            # millis() since device boot
    }

The host adds a `received_at_utc` timestamp on ingestion. Downstream services
(queue producer, cloud worker) will add further timestamps on their own hops.

Publishing to Azure Service Bus
-------------------------------
By default, parsed events are also published to an Azure Service Bus queue.
The Service Bus message's MessageId is set to the event's `event_id`, which
enables Service Bus's built-in duplicate detection to deduplicate retries
within the configured detection window.

Configuration:
    SERVICEBUS_CONNECTION_STRING   environment variable, required when publishing
    --queue NAME                   queue name (default: rfid-events)
    --no-publish                   listen-only mode; skip Service Bus entirely

For Post 9, failure handling is deliberately minimal — a failed publish logs
and continues. The local SQLite buffer with retry-with-backoff comes in the
next iteration; this version proves the happy-path connection works.
"""

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from typing import Optional

import serial

# Service Bus is imported lazily inside main() so that:
#   1. The pure-Python parts of this module (parse_event, format_device_ms)
#      can be imported and tested without azure-servicebus installed.
#   2. Running with --no-publish does not require the SDK at all.
# The import happens once at startup when publishing is enabled.


EVENT_PREFIX = "EVENT:"

# Fields the device is expected to send. Anything else is ignored on the
# host side — additive schema changes won't break this ingestor.
REQUIRED_FIELDS = {"event_id", "device_id", "firmware_version", "uid", "valid", "ts_device_ms"}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Listen for RFID events from a serial-connected microcontroller."
    )
    parser.add_argument("--port", default="COM3", help="Serial port name, for example COM3")
    parser.add_argument("--baud", type=int, default=9600, help="Serial baud rate")
    parser.add_argument(
        "--timeout",
        type=float,
        default=2.0,
        help="Read timeout in seconds",
    )
    parser.add_argument(
        "--quiet-non-events",
        action="store_true",
        help="Suppress raw output for non-EVENT lines",
    )
    parser.add_argument(
        "--queue",
        default="rfid-events",
        help="Service Bus queue name (default: rfid-events)",
    )
    parser.add_argument(
        "--no-publish",
        action="store_true",
        help="Skip Service Bus publishing; listen and print only",
    )
    return parser


def parse_event(line: str) -> Optional[dict]:
    """
    Parse a single serial line into an event dict. Returns None if the line
    is not an EVENT: line. Raises ValueError if the payload shape is wrong.
    """
    if not line.startswith(EVENT_PREFIX):
        return None

    payload = line[len(EVENT_PREFIX):]
    data = json.loads(payload)

    missing = REQUIRED_FIELDS - data.keys()
    if missing:
        # Backward-compatible behaviour: if a pre-schema device is still in the
        # field, mint a host-side event_id and tag the device as "unknown" so
        # downstream consumers can still process and trace the event. Any other
        # missing field is a hard failure — those carry semantic meaning we
        # cannot fabricate.
        critical = missing - {"event_id", "device_id", "firmware_version"}
        if critical:
            raise ValueError(f"Missing required fields {missing}: {data}")

        if "event_id" in missing:
            data["event_id"] = str(uuid.uuid4())
        if "device_id" in missing:
            data["device_id"] = "unknown"
        if "firmware_version" in missing:
            data["firmware_version"] = "unknown"

    # Type checks. Catch wire-format drift early rather than letting bad
    # data flow into the queue and DB downstream.
    if not isinstance(data["event_id"], str):
        raise ValueError(f"event_id must be string: {data}")
    if not isinstance(data["device_id"], str):
        raise ValueError(f"device_id must be string: {data}")
    if not isinstance(data["firmware_version"], str):
        raise ValueError(f"firmware_version must be string: {data}")
    if not isinstance(data["uid"], str):
        raise ValueError(f"uid must be string: {data}")
    if not isinstance(data["valid"], bool):
        raise ValueError(f"valid must be bool: {data}")
    if not isinstance(data["ts_device_ms"], int):
        raise ValueError(f"ts_device_ms must be int: {data}")

    return {
        "event_id": data["event_id"],
        "device_id": data["device_id"],
        "firmware_version": data["firmware_version"],
        "uid": data["uid"],
        "valid": data["valid"],
        "ts_device_ms": data["ts_device_ms"],
        "received_at_utc": datetime.now(timezone.utc).isoformat(),
    }


def format_device_ms(ms: int) -> str:
    """
    Render a millis()-since-boot value as a human-readable uptime string,
    while keeping the raw number visible for diagnostics. Examples:
        20341     -> "20.341s (uptime 0:00:20)"
        65000     -> "65.000s (uptime 0:01:05)"
        3725000   -> "3725.000s (uptime 1:02:05)"
    The raw ms value stays in the event dict; only the display changes.
    """
    seconds_total = ms / 1000.0
    hours, remainder = divmod(int(seconds_total), 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{seconds_total:.3f}s (uptime {hours}:{minutes:02d}:{seconds:02d})"


def print_event(event: dict) -> None:
    print("PARSED EVENT:")
    print(f"  Event ID    : {event['event_id']}")
    print(f"  Device ID   : {event['device_id']}")
    print(f"  Firmware    : {event['firmware_version']}")
    print(f"  UID         : {event['uid']}")
    print(f"  Valid       : {event['valid']}")
    print(f"  Since boot  : {format_device_ms(event['ts_device_ms'])}")
    print(f"  Received at : {event['received_at_utc']}")
    print()


def publish_event(sender, event: dict) -> bool:
    """
    Publish a parsed event to Service Bus. Returns True on success, False
    on any failure (which is logged but does not raise — the listener stays
    alive so subsequent scans keep working).

    The Service Bus MessageId is set to event_id so duplicate detection
    catches retries automatically. Same card tapped 10 times in a 10-minute
    window reaches the consumer once, because the device-generated UUIDs
    let Service Bus collapse exact retransmissions.

    The buffer-and-retry layer that handles offline operation is a separate
    change — this function deliberately stays simple for now. When the
    buffer arrives, it wraps this function's body without changing the
    call site in main().
    """
    # Imported here, not at module top, so the function signature below
    # can use a generic `sender` type without forcing the import on
    # callers that don't publish.
    from azure.servicebus import ServiceBusMessage

    try:
        msg = ServiceBusMessage(json.dumps(event))
        msg.message_id = event["event_id"]
        sender.send_messages(msg)
        print(f"  Published   : event_id={event['event_id']}")
        return True
    except Exception as ex:
        # Broad catch is intentional for this iteration: any publish failure
        # is treated equivalently (log and move on). When the local buffer
        # arrives, this branch will write to SQLite and trigger the
        # background retry thread instead of just logging.
        print(f"  Publish FAILED: {type(ex).__name__}: {ex}")
        return False


def _read_loop(connection, args, sender) -> int:
    """
    The serial-read main loop, factored out so main() can wrap it with
    the Service Bus client/sender context managers cleanly.
    """
    print(f"Connected to {args.port} at {args.baud} baud")
    if sender is not None:
        print(f"Publishing to Service Bus queue: {args.queue}")
    else:
        print("Service Bus publishing disabled (--no-publish)")
    print("Listening for RFID events...")

    while True:
        try:
            raw_bytes = connection.readline()
            if not raw_bytes:
                continue

            line = raw_bytes.decode("utf-8", errors="replace").strip()
            if not line:
                continue

            event = parse_event(line)

            if event is None:
                if not args.quiet_non_events:
                    print(f"RAW: {line}")
                continue

            print(f"RAW: {line}")
            print_event(event)

            if sender is not None:
                publish_event(sender, event)

        except json.JSONDecodeError as ex:
            print(f"JSON parse error: {ex}")
        except ValueError as ex:
            print(f"Payload error: {ex}")
        except KeyboardInterrupt:
            print("\nStopping listener.")
            return 0


def main() -> int:
    args = build_parser().parse_args()

    # Decide whether to publish. If publishing is enabled, fail fast on
    # missing connection string — better an explicit error at startup than
    # confusing per-event publish failures every time a card is scanned.
    if args.no_publish:
        connection_string = None
    else:
        connection_string = os.environ.get("SERVICEBUS_CONNECTION_STRING")
        if not connection_string:
            print(
                "ERROR: SERVICEBUS_CONNECTION_STRING environment variable is not set.\n"
                "       Either set it (see README) or pass --no-publish to run in\n"
                "       listen-only mode."
            )
            return 2

    print(f"Opening {args.port} at {args.baud} baud...")
    try:
        with serial.Serial(args.port, args.baud, timeout=args.timeout) as connection:
            if connection_string is None:
                # Listen-only mode: no Service Bus client at all.
                return _read_loop(connection, args, sender=None)

            # Publish mode: open one client + sender for the lifetime of
            # the process. Per-event opens would add a TCP+AMQP handshake
            # to every scan, which is wasteful and visibly slower.
            from azure.servicebus import ServiceBusClient

            with ServiceBusClient.from_connection_string(connection_string) as client:
                with client.get_queue_sender(args.queue) as sender:
                    return _read_loop(connection, args, sender=sender)

    except serial.SerialException as ex:
        print(f"Unable to open serial port {args.port}: {ex}")
        print("Check the COM port number and make sure no other app is using the serial port.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
