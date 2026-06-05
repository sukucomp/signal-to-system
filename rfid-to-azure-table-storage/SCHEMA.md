# RFID Event Schema (v1)

This document defines the wire format emitted by RFID reader devices,
consumed by the host-side ingestor, published to Service Bus, and
written to Azure Table Storage. It is intentionally small, additive,
and stable across the rest of the series.

## Wire format

Each scan produces one newline-terminated line on the serial port:

```
EVENT:{"event_id":"<uuid>","device_id":"<id>","firmware_version":"<ver>","uid":"<hex>","valid":<bool>,"ts_device_ms":<int>}
```

Example:

```
EVENT:{"event_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","device_id":"reader-01","firmware_version":"1.3.0","uid":"64 7D 49 BF","valid":true,"ts_device_ms":12345}
```

The `EVENT:` prefix lets the host filter signal from any debug noise
the device may print outside scan events (boot banners, error logs).

## Fields

| Field              | Type    | Source | Purpose                                                                 |
|--------------------|---------|--------|-------------------------------------------------------------------------|
| `event_id`         | string  | device | UUID v4. Idempotency key for at-least-once delivery downstream.         |
| `device_id`        | string  | device | Identifies which reader produced the event. Provisioned per device.     |
| `firmware_version` | string  | device | Firmware running on the device. Bump on every behavior-affecting change.|
| `uid`              | string  | device | Card UID, hex bytes separated by spaces.                                |
| `valid`            | bool    | device | Result of the device's local allow-list check.                          |
| `ts_device_ms`     | integer | device | `millis()` since device boot. Not wall-clock; relative within a boot.   |

## Host-added fields

When the ingestor parses an event, it adds:

| Field             | Type   | Source | Purpose                                                  |
|-------------------|--------|--------|----------------------------------------------------------|
| `received_at_utc` | string | host   | ISO-8601 UTC timestamp at which the host read the line.  |

## Cloud-added fields (added in this stage)

When the Azure Function processes a message, it adds:

| Field              | Type   | Source | Purpose                                                  |
|--------------------|--------|--------|----------------------------------------------------------|
| `processed_at_utc` | string | cloud  | UTC timestamp at which the Function wrote the row.       |

Three timestamps, three hops (device → host → cloud), full visibility
into where latency accumulates. The observability post later in the
series uses these to compute per-hop and end-to-end latencies.

## Why each field exists

**`event_id` (device-generated UUID v4).** The single most important
addition. Once the pipeline includes a queue with retry semantics, the
consumer must be able to tell "I have already processed this event"
from "this is a new event." Without an immutable, device-generated key,
deduplication is impossible — host or queue timestamps are not unique
enough. Generating it on the device means the same key flows end-to-end.

The Arduino implementation seeds the RNG from a floating analog pin
and generates UUID v4s inline. This is not cryptographically secure;
it is sufficient for deduplication of scan events but should not be
used as an authentication token or against an adversarial setting.

**`device_id`.** A single-reader prototype does not need this. A
fleet of 50 readers absolutely does. Queries like "which reader is
failing?", "which doors had the most denials this hour?", and "is
reader-12 still online?" all require it. Provisioned at flash time as
a simple constant in this stage; in a production fleet it would
typically be derived from a hardware identifier or assigned during
onboarding.

**`ts_device_ms`.** Arduino has no real-time clock. `millis()` resets
on every reboot, so it is not useful as wall-clock time — but it *is*
useful for measuring intervals on the device itself and for detecting
reboots (a sudden drop from a high value to a low one). Wall-clock
time is added by the host and later by the cloud, where reliable
clocks exist.

**`firmware_version`.** Trivially available — the device knows what
it is running, because *we* set the constant when flashing. Including
it in every event means any anomaly seen at the cloud layer ("denials
spiked after Tuesday") can be correlated with a firmware change
without needing a separate fleet-inventory lookup.

## Compatibility behaviour

The host-side ingestors accept events that are missing `event_id`,
`device_id`, or `firmware_version` and fill in defaults (`uuid4()`
host-side, `"unknown"` for the others). This lets a partial fleet
upgrade work without a flag day. Any other missing field is a hard
failure — those carry semantic meaning that cannot be fabricated.

## Cloud mapping — Service Bus (carried from previous stage)

When the host publishes an event to Azure Service Bus, two things
happen to the schema:

1. **The whole event becomes the message body.** The host serialises
   the parsed event as snake_case JSON. Both ingestors emit identical
   bytes regardless of language.
2. **`event_id` becomes the Service Bus `MessageId`.** This is the
   choice that makes Service Bus's built-in duplicate detection
   useful — with the dedup window enabled, Service Bus collapses any
   retransmission of the same MessageId into a single delivered
   message.

## Cloud mapping — Table Storage (added in this stage)

When the Azure Function consumes a message and writes to Table
Storage, the event maps to a row as follows:

| Table Storage column | Source field    | Notes                                          |
|----------------------|-----------------|------------------------------------------------|
| `PartitionKey`       | `device_id`     | Groups all events from one reader              |
| `RowKey`             | `event_id`      | Unique per row; makes writes idempotent        |
| `FirmwareVersion`    | `firmware_version` | (renamed for PascalCase storage convention) |
| `Uid`                | `uid`           |                                                |
| `Valid`              | `valid`         |                                                |
| `TsDeviceMs`         | `ts_device_ms`  |                                                |
| `ReceivedAtUtc`      | `received_at_utc` |                                              |
| `ProcessedAtUtc`     | (new, generated) | UTC moment the function wrote the row         |

The choice of `event_id` as RowKey is what makes the storage write
idempotent: if Service Bus's at-least-once delivery results in the
same message being delivered twice, the function processes it twice
and writes to the same RowKey twice — but the second write is a
harmless replace, not a duplicate row.

This is the third defence anchored on `event_id`: it is the per-tap
identity, the Service Bus dedup key, AND the idempotent storage key.
Same field, three layers, against the messy reality of retries and
partial failures.

## Schema versioning

The schema is currently unversioned. Any future breaking change will
introduce an explicit `schema_version` field and the host ingestors
will branch on it. Until then, all changes are additive: new fields
may appear, but no field is removed or repurposed.

## What this schema does *not* yet include

- **`read_rssi` and `antenna_port`** — UHF concepts that the MFRC522
  (HF, single fixed antenna) cannot supply. They will appear when this
  series moves to a UHF reader.
- **`signature`** — for tamper-evident events. Out of scope until a
  defined threat model and a hardware secure element exist to back it.
  A sloppy signature is worse than no signature in an access-control
  context.
