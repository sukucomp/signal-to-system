# RFID Event Schema (v1)

This document defines the wire format emitted by RFID reader devices and
consumed by the host-side ingestor. It is intentionally small, additive,
and stable across the rest of the series.

## Wire format

Each scan produces one newline-terminated line on the serial port:

```
EVENT:{"event_id":"<uuid>","device_id":"<id>","firmware_version":"<ver>","uid":"<hex>","valid":<bool>,"ts_device_ms":<int>}
```

Example:

```
EVENT:{"event_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","device_id":"reader-01","firmware_version":"1.1.0","uid":"64 7D 49 BF","valid":true,"ts_device_ms":12345}
```

The `EVENT:` prefix lets the host filter signal from any debug noise the
device may print outside scan events (boot banners, error logs, etc.).

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

Downstream stages (queue producer, cloud worker, database writer) will
each add their own timestamps as the event traverses the pipeline. This
gives observability into where latency or backpressure accumulates.

## Why each field exists

**`event_id` (device-generated UUID v4).** The single most important
addition. Once the pipeline includes a queue with retry semantics, the
consumer must be able to tell "I have already processed this event"
from "this is a new event." Without an immutable, device-generated key,
deduplication is impossible — host or queue timestamps are not unique
enough. Generating it on the device means the same key flows end-to-end.

The Arduino implementation seeds the RNG from a floating analog pin and
generates UUID v4s inline. This is not cryptographically secure; it is
sufficient for de-duplication of scan events but should not be used as
an authentication token or against an adversarial setting.

**`device_id`.** A single-reader prototype does not need this. A fleet
of 50 readers absolutely does. Queries like "which reader is failing?",
"which doors had the most denials this hour?", and "is reader-12 still
online?" all require it. Provisioned at flash time as a simple constant
in this stage; in a production fleet it would typically be derived from
a hardware identifier (MAC, chip serial) or assigned during onboarding.

**`ts_device_ms`.** Arduino has no real-time clock. `millis()` resets
on every reboot, so it is not useful as wall-clock time — but it *is*
useful for measuring intervals on the device itself ("how long between
scans on this reader?") and for detecting reboots (a sudden drop from a
high value to a low one). Wall-clock time is added by the host and
later by the cloud, where reliable clocks exist.

**`firmware_version`.** Trivially available — the device knows what it
is running, because *we* set the constant when flashing. Including it
in every event means any anomaly seen at the cloud layer ("denials
spiked after Tuesday") can be correlated with a firmware change without
needing a separate fleet-inventory lookup. The discipline that makes
this field actually useful is bumping the version on *every* change to
the sketch that affects what it emits or how it behaves. A field that
always reads `1.0.0` is just decoration.

## Compatibility behaviour

The host-side ingestors (Python and C#) accept events that are missing
`event_id`, `device_id`, or `firmware_version` and fill in defaults
(`uuid4()` host-side, `"unknown"` for the others). This is deliberate:
it lets a partial fleet upgrade work without a flag day. Any other
missing field is a hard failure — those carry semantic meaning that
cannot be fabricated.

## What this schema does *not* yet include

These are deliberate omissions. Each will be added when the relevant
post in the series justifies it — and when the underlying hardware or
threat model can support it honestly.

- **`read_rssi` and `antenna_port`** — these are UHF concepts. RSSI
  measures how strongly a tag's response came back, which matters when
  tags are metres away and orientation is variable. Antenna port
  identifies which of several antennas saw the tag. The MFRC522 used in
  this stage is an HF (13.56 MHz) reader operating in the *near-field*,
  with a single fixed antenna coil. There is no meaningful signal
  strength to report (the tag is either coupled to the coil or it
  isn't) and no port to identify (there is one). Adding these fields
  now would mean either hardcoding meaningless constants or sending
  `null` — both teach downstream systems to expect data the device
  cannot honestly provide. They will be introduced in the post that
  moves to a UHF reader.
- **`signature`** — for tamper-evident events in access-control
  deployments. Out of scope not because it is hard to add a field, but
  because doing it badly is worse than not doing it. A meaningful
  signature requires answers to questions this series has not yet
  posed: what gets signed (raw payload? canonical form? JSON
  serialization is non-deterministic), what signs it (HMAC with a
  shared key? asymmetric signing from a hardware secure element like
  ATECC608A?), who verifies, and what the threat model actually is.
  A field labelled `signature` that is actually `sha256(payload + "secret")`
  provides the *appearance* of authenticity without the substance,
  which is worse in an access-control context than not having it at
  all. Deferred until a deployment scenario in the series genuinely
  calls for it, with hardware to back it.

## Schema versioning

The schema is currently unversioned. Any future breaking change will
introduce an explicit `schema_version` field and the host ingestors
will branch on it. Until then, all changes are additive: new fields
may appear, but no field is removed or repurposed.
