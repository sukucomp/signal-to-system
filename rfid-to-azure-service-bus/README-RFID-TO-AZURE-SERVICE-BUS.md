# RFID to Azure Service Bus

This is the cloud hop. Events from Posts 5–7 stayed on the local machine.
Here, every scan is published to an Azure Service Bus queue with the
device-generated `event_id` as the Service Bus `MessageId` — the
idempotency key designed in Post 7 doing real work in real cloud
infrastructure.

> Companion post: **Signal to System #8 — From Schema to Pipeline: First Cloud Hop**
> *(LinkedIn link to be added once published)*

## What's in this folder

| File | Role |
|---|---|
| `rfid-valid-uid-to-python.ino` | Arduino sketch (unchanged from previous folder; carried for self-containment) |
| `rfid-serial-ingestor-az-service-bus.py` | Python ingestor that reads serial events and publishes to Service Bus |
| `rfid-serial-ingestor-az-service-bus.cs` | C# ingestor doing the same, in mirror-image structure |
| `RfidReader.csproj` | C# project file (referenced packages: `Azure.Messaging.ServiceBus`, `System.IO.Ports`) |
| `SCHEMA.md` | The event contract (carried forward from Post 7, no change in v1.3.0) |
| `README.md` | This file |

The Arduino sketch is identical to the one from `rfid-to-windows-serial-port/`.
It's duplicated here deliberately — each folder is meant to be self-sufficient,
so a reader following the LinkedIn series can clone *one* folder and have
everything needed for *that* post to work. Path of least friction beats
strict DRY for portfolio code.

## Pipeline at this stage

```
Arduino (MFRC522)
       │  USB serial @ 9600 baud
       │  EVENT:{"event_id":"...","device_id":"reader-01",...}
       ▼
Host ingestor (Python or C#)
       │  parse + validate + add received_at_utc
       │  publish with MessageId = event_id
       ▼
Azure Service Bus queue (rfid-events)
       │  duplicate detection: 10-minute window
       │  dead-letter queue for poison messages
       ▼
[ Post 9: cloud consumer + offline buffering ]
```

## Prerequisites

- An Azure subscription with a Service Bus namespace (Standard tier — Basic
  doesn't support duplicate detection)
- A queue named `rfid-events` in that namespace, with **duplicate detection
  enabled** (10-minute window is fine)
- Arduino Uno + MFRC522 reader, flashed with the included `.ino`
- Python 3.10+ or .NET 8.0+ on the host

## Configuration

Both ingestors read the Service Bus connection string from the
`SERVICEBUS_CONNECTION_STRING` environment variable. Get the value from
the Azure portal:

> Service Bus namespace → Shared access policies → `RootManageSharedAccessKey`
> → Primary Connection String → copy

In PowerShell:

```powershell
$env:SERVICEBUS_CONNECTION_STRING = "Endpoint=sb://<service_bus_namespace-host_name>;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=..."
```

The variable is per-PowerShell-session. Reopen a window, set it again.

## Running the Python ingestor

```powershell
python -m pip install -r requirements.txt   # pyserial, azure-servicebus
python -u rfid_serial_ingestor.py --port COM3 --baud 9600
```

Useful flags:

- `--queue NAME` — defaults to `rfid-events`
- `--no-publish` — listen-only mode, skip Service Bus entirely
  (useful when iterating without an Azure subscription handy)

## Running the C# ingestor

```powershell
dotnet add package Azure.Messaging.ServiceBus
dotnet add package System.IO.Ports
dotnet build
dotnet run -- --port COM3 --baud 9600
```

(The `--` separates `dotnet`'s flags from the program's flags.)

The C# ingestor accepts the same `--port`, `--baud`, `--queue`, and
`--no-publish` flags as the Python ingestor.

## Verifying it works

1. Run either ingestor (one at a time — both can publish to the same queue,
   but a single COM port can only be opened by one process at a time).
2. Tap a card.
3. Watch the terminal show:
   ```
   PARSED EVENT:
     Event ID    : a1b2c3d4-...
     ...
     Published   : event_id=a1b2c3d4-...
   ```
4. In the Azure portal, navigate to the queue → Service Bus Explorer → Peek.
5. The message appears with `MessageId = a1b2c3d4-...` matching the `event_id`
   from the terminal.

The producer-side pipeline is then complete.

## Verifying duplicate detection

Tap the **same card** five times in 30 seconds. You'll see five messages
in the queue, each with a *different* `event_id` — because each tap is
a real, distinct event. That's correct: the user tapped five times.

To verify duplicate detection is actually firing, send the *same MessageId*
deliberately (a small one-off script can do this — supply the same UUID for
five sends in a row). Service Bus will collapse them into one message.

The same `event_id` field plays two roles: a unique key per real-world
tap, and a deduplication key against infrastructure retries. Either
job alone wouldn't be enough.

## What's not yet in this folder

- A consumer reading from the queue. Right now messages accumulate.
  Coming in Post 9.
- A local SQLite buffer for offline operation. Right now a network
  failure during publish is logged and skipped — the event is lost.
  Coming in Post 9.
- Managed identity authentication. See the production note above.
- CI workflow to compile the Arduino sketch and build the .NET project
  on every push. Reserved for a later post.

## Cost note

A Standard-tier Service Bus namespace runs roughly USD $10/month at
base. Tearing it down between development sessions saves money;
re-creating takes about two minutes through the portal. For a portfolio
project, provision-demo-record-tear-down is the right pattern.
