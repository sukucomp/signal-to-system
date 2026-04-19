# RFID-Based Authentication System with Python Serial Monitoring
This project shows flow as below:

1. An RFID card is tapped on the reader.
2. The microcontroller reads the UID.
3. The UID is validated against an allow-list.
4. A display and buzzer provide immediate feedback.
5. A structured serial event is sent to the local machine.
6. A Python script listens on the serial port and prints parsed events.

## Files

- `rfid_reader.ino`
  Arduino sketch for RFID validation, on-device feedback, and serial event output.
- `rfid_serial_ingestor.py`
  Python serial listener that reads `EVENT:{...}` messages and prints parsed output.

## Serial Event Format

Each scan is emitted as a single line:

```text
EVENT:{"uid":"64 7D 49 BF","valid":true}
```

## Python Setup

Install the dependency:

```powershell
pip install pyserial
```

Run the listener:

```powershell
python -u rfid_serial_ingestor.py --port COM3 --baud 9600
```

Optional:

```powershell
python -u rfid_serial_ingestor.py --port COM3 --baud 9600 --quiet-non-events
```

## Notes

- Make sure the serial port in the Python script matches the port assigned to the board in Windows.
- Close Arduino Serial Monitor before running the Python listener, otherwise the COM port may already be in use.
- Update the `VALID_UIDS` array in the Arduino sketch to match your RFID cards.
