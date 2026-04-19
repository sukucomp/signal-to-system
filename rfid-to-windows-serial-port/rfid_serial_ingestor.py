import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Optional

import serial


EVENT_PREFIX = "EVENT:"


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
    if not line.startswith(EVENT_PREFIX):
        return None

    payload = line[len(EVENT_PREFIX) :]
    data = json.loads(payload)

    uid = data.get("uid")
    valid = data.get("valid")

    if not isinstance(uid, str) or not isinstance(valid, bool):
        raise ValueError(f"Unexpected event payload: {data}")

    return {
        "uid": uid,
        "valid": valid,
        "time_utc": datetime.now(timezone.utc).isoformat(),
    }


def print_event(event: dict) -> None:
    print("PARSED EVENT:")
    print(f"UID   : {event['uid']}")
    print(f"Valid : {event['valid']}")
    print(f"Time  : {event['time_utc']}")
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
