# RFID to Azure Table Storage

This stage closes the cloud loop. Events that landed in the Service Bus
queue in the previous stage are now consumed by an Azure Function and
written as rows in Azure Table Storage — so a card tap finally *arrives*
somewhere visible in the cloud, end to end.

> Companion post: **Signal to System #10 — The Loop Closes**
> *(https://www.linkedin.com/pulse/signal-system-10-loop-closes-suresh-balasubramaniam-jwhvc/)*

## What this folder adds over the previous stage

The previous folder (`rfid-to-azure-service-bus/`) ended at the queue —
events were published successfully, but nothing read them. This folder
adds the consumer:

- An **Azure Function** with a Service Bus trigger that fires on each
  queued message
- Parses the event JSON, then writes a row to **Azure Table Storage**
- `device_id` becomes the row's PartitionKey; `event_id` becomes the
  RowKey — the same UUID the Arduino chose for the original tap

The full pipeline now traces: card → Arduino → ingestor → Service Bus
→ Function → Table Storage. Six hops, one identity (the device-generated
`event_id`) flowing through every one.

## What's in this folder

| Path | Role |
|---|---|
| `SCHEMA.md` | The event contract (carried from previous stage, with a Table Storage mapping section added) |
| `arduino/rfid-valid-uid-to-python.ino` | Arduino sketch (carried for self-containment) |
| `host-ingestor/` | Python and C# ingestors that publish to Service Bus (carried from previous stage) |
| `az-function-consumer/` | NEW — the cloud-side consumer that reads the queue and writes to Table Storage |

## Pipeline at this stage

```
Arduino (MFRC522)
       │  USB serial @ 9600 baud
       ▼
Host ingestor (Python or C#)
       │  publish, MessageId = event_id
       ▼
Azure Service Bus queue (rfid-events)
       │  Service Bus trigger fires
       ▼
Azure Function: RfidEventConsumer (.NET 10 isolated, Flex Consumption)
       │  parse + write
       ▼
Azure Table Storage (sasignaltosystemdev / rfidevents)
       │  PartitionKey = device_id
       │  RowKey       = event_id
```

## Why these storage keys

Two deliberate choices:

**PartitionKey = `device_id`.** When a future query asks "show me
everything reader-12 saw last Tuesday," the storage layer answers it
cheaply — all of one reader's events live in one partition. This is
the structure a 50-reader fleet would need.

**RowKey = `event_id`.** The same UUID that lives on the Service Bus
message becomes the row's identifier. Two consequences worth noting:

1. Every row is uniquely identified by the same string that travelled
   through every other hop. End-to-end traceability for free.
2. The write is idempotent. If a network blip causes the function to
   process the same message twice, the second write hits the same
   RowKey and is a harmless overwrite, not a duplicate row.

The `event_id` field now plays *three* roles end-to-end: per-tap
identity, Service Bus deduplication key, and idempotent storage key.
None of those would work if the UUID had been generated host-side or
cloud-side instead of on the device.

## Prerequisites

- Everything from the previous stage (Arduino flashed, Service Bus
  namespace running, queue created)
- An Azure Storage account (the same one used by the Function App's
  internal storage is fine)
- An Azure Function App, .NET 10 isolated, Flex Consumption plan
- App settings on the Function App:
  - `ServiceBusConnection` — same connection string as the ingestor
  - `TableStorageConnection` — the storage account's connection string

## How to deploy the Function

The function project lives in `az-function-consumer/`. Open that
subfolder in VS Code, then either:

1. **VS Code Azure Functions extension** (recommended) — right-click
   the Function App in the Azure panel → Deploy to Function App.
2. **CLI** — `func azure functionapp publish <function-app-name>`
   after building with `dotnet publish`.

The first run will trigger a NuGet restore that takes a minute or two;
subsequent deploys are fast.

## How to verify it works

1. Start the host ingestor in one terminal (with
   `SERVICEBUS_CONNECTION_STRING` set as before).
2. Open the Function App in the Azure portal → Functions →
   `RfidEventConsumer` → **Invocations** tab.
3. Tap a card. Within a second or two, a new invocation appears in the
   list.
4. In the storage account → **Storage browser** → **Tables** →
   `rfidevents`, refresh. A new row appears, with PartitionKey
   matching the device_id and RowKey matching the event_id from the
   ingestor's terminal output.

## What's not yet in this folder

- **No offline buffering on the ingestor side.** If the network drops
  during publish, the event is currently logged and lost. The local
  SQLite ring buffer with retry-with-backoff is the subject of the
  next post.
- **Connection strings, not managed identity.** The Function App uses
  connection strings stored as app settings. Production would use
  Microsoft Entra ID with a managed identity. Deferred to a later post
  when the consumer moves to containerised compute and identity
  infrastructure earns its place.
- **No infrastructure-as-code.** All resources were created through
  the Azure Portal. Bicep / Terraform versions are deferred — they
  earn their own post when the topology stabilises.
- **No structured logging or KQL queries.** Application Insights is
  enabled and capturing data, but no dashboards or alerts yet. The
  observability post is later in the series.

## A note on cost

The Function App runs on Flex Consumption (scale to zero, pay per
execution). At demo volume — a handful of card taps per day — the cost
is essentially zero. The Service Bus Standard namespace has a small
flat hourly fee (~USD $0.30/day). Total infrastructure cost for the
running demo is under a dollar a day, and substantially less if torn
down between sessions.
