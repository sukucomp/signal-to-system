This project shows flow as below:

1. An RFID card is tapped on the reader.
2. The microcontroller reads the UID.
3. The UID is validated against an allow-list.
4. A display and buzzer provide immediate feedback.
5. A structured serial event is sent to the local machine.
6. A listener (Python or C#) reads from the serial port and prints parsed events.

## Files

- `rfid-valid-uid-to-python.ino`
  Arduino sketch for RFID validation, on-device feedback, and serial event output.
- `rfid_serial_ingestor.py`
  Python serial listener that reads `EVENT:{...}` messages and prints parsed output.
- `program.cs`
  C# console application that listens to the serial port, parses events, and prints output.

## Serial Event Format

Each scan is emitted as a single line:

```text
EVENT:{"event_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","device_id":"reader-01","firmware_version":"1.1.0","uid":"64 7D 49 BF","valid":true,"ts_device_ms":12345}
```

## Python Setup

Navigate to the folder where your Python ingestor is located.

Install the dependency:

```powershell
pip install pyserial
```

Run the listener:

```powershell
python -u rfid_serial_ingestor.py --port COM3 --baud 9600
```

## C# Setup (.NET)

Navigate to the folder where your C# ingestor is located.

Prerequisites
Install .NET SDK (version 6 or later recommended)

Verify installation:

```powershell
dotnet --version
```

Create Project (if not already created):

```powershell
dotnet new console -n RfidReader
cd RfidReader
```

Add Required Package:

```powershell
dotnet add package System.IO.Ports
```

Replace the contents of (or replace the file):

```powershell
RfidReader/Program.cs
```
with the C# RFID ingestor code.

Build:

```powershell
dotnet build
```

Run:

```powershell
dotnet run
```

Expected output:

```powershell
Opening COM3 at 9600 baud...
Connected to COM3
Listening for RFID events...
```

When a card is scanned:

```powershell
RAW: EVENT:{"event_id":"03acda01-be06-4542-a7ab-aebfb85b3fc0","device_id":"reader-01","firmware_version":"1.3.0","uid":"64 7D 49 BF","valid":true,"ts_device_ms":3827}
PARSED EVENT:
  Event ID    : 03acda01-be06-4542-a7ab-aebfb85b3fc0
  Device ID   : reader-01
  Firmware    : 1.3.0
  UID         : 64 7D 49 BF
  Valid       : True
  Since boot  : 3.827s (uptime 0:00:03)
  Received at : 2026-05-10T13:53:28.340284+00:00
```

## Notes

- Make sure the serial port in the Python script matches the port assigned to the board in Windows.
- Close Arduino Serial Monitor before running the Python listener, otherwise the COM port may already be in use.
- Baud rate must match Arduino configuration (e.g., Serial.begin(9600)).
- Ensure the Arduino sends newline-terminated output (Serial.println).
- Update the `VALID_UIDS` array in the Arduino sketch to match your RFID cards.
