# rfid-event-consumer-containerized

Standalone Python worker that replaces the Azure Functions-based
consumer (`../rfid-to-azure-table-storage/az-function-consumer/`) with
a containerized service running on Azure Container Apps, scaled by
KEDA based on Service Bus queue depth.

Behavior is ported 1:1 from `rfid-event-consumer-az-function.cs`:
same event schema, same Table Storage layout (PartitionKey=device_id,
RowKey=event_id), same idempotent upsert-replace write, same
malformed-message handling. The difference is *how* it runs — an
explicit receive loop instead of a Functions trigger — not what it
does.

## Files

| File | Purpose |
|---|---|
| `worker.py` | Service Bus receive loop + Table Storage write logic |
| `config.py` | Reads connection info from environment variables |
| `Dockerfile` | Multi-stage build: slim runtime, non-root user |
| `requirements.txt` | `azure-servicebus`, `azure-data-tables` |
| `.env.example` | Template for required/optional env vars |
| `.dockerignore` | Keeps local secrets and caches out of the build context |

## Running locally

```bash
cp .env.example .env   # fill in real connection strings
pip install -r requirements.txt
python worker.py
```

Or via Docker:

```bash
docker build -t rfid-consumer:dev .
docker run --rm --env-file .env rfid-consumer:dev
```

Graceful shutdown: SIGINT/SIGTERM are handled, so `Ctrl+C` locally or
`docker stop` / a Container Apps scale-down both exit cleanly between
polls rather than mid-operation.

## Deployed as

Azure Container App `ca-rfid-consumer-dev`, image pushed to
`acrsignaltosystemdev.azurecr.io/rfid-consumer`, scaled by a KEDA
`azure-servicebus` rule (min 0 / max 1 replicas, triggers at 5 queued
messages) watching the `rfid-events` queue.

See LinkedIn post #13 for the full narrative and trade-off discussion
(Functions vs. Container Apps).
