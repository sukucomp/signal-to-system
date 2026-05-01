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

## C# Setup (.NET)

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

Replace Program.cs
Replace the contents of:

```powershell
RfidReader/Program.cs
```
with the C# RFID listener code.

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
RAW: EVENT:{"uid":"64 7D 49 BF","valid":true}
PARSED EVENT:
UID   : 64 7D 49 BF
Valid : True
Time  : 2026-04-27T12:00:00Z
```

## Notes

- Make sure the serial port in the Python script matches the port assigned to the board in Windows.
- Close Arduino Serial Monitor before running the Python listener, otherwise the COM port may already be in use.
- Baud rate must match Arduino configuration (e.g., Serial.begin(9600)).
- Ensure the Arduino sends newline-terminated output (Serial.println).
- Update the `VALID_UIDS` array in the Arduino sketch to match your RFID cards.
