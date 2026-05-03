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
"""

import argparse
import json
import sys
import uuid
from datetime import datetime, timezone
from typing import Optional

import serial


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


def main() -> int:
    args = build_parser().parse_args()

    print(f"Opening {args.port} at {args.baud} baud...")
    try:
        with serial.Serial(args.port, args.baud, timeout=args.timeout) as connection:
            print(f"Connected to {args.port} at {args.baud} baud")
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
                except json.JSONDecodeError as ex:
                    print(f"JSON parse error: {ex}")
                except ValueError as ex:
                    print(f"Payload error: {ex}")
                except KeyboardInterrupt:
                    print("\nStopping listener.")
                    return 0
    except serial.SerialException as ex:
        print(f"Unable to open serial port {args.port}: {ex}")
        print("Check the COM port number and make sure no other app is using the serial port.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
