using System.Text.Json;
using System.Text.Json.Serialization;
using Azure;
using Azure.Data.Tables;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace ServiceBusToTable;

// =====================================================================
// RFID event consumer.
//
// Triggered automatically by Service Bus when a message lands in the
// rfid-events queue. Parses the JSON event published by the host-side
// ingestor (Python or C#), then writes a row to Table Storage in the
// account configured by TableStorageConnection.
//
// Storage layout:
//   PartitionKey = device_id   (e.g. "reader-01")
//   RowKey       = event_id    (device-generated UUID v4)
//
// Why these keys:
//   - Partitioning by device_id makes "show me everything reader-NN
//     saw" a fast, narrow query — important once a fleet has many
//     readers producing many events.
//   - RowKey = event_id gives every row a unique identity, AND makes
//     the write idempotent: a duplicate retry of the same event hits
//     the same RowKey and is a harmless overwrite, not a second row.
//     This is the third layer of idempotency, after the device UUID
//     and the Service Bus duplicate-detection window. Same field,
//     three defenses.
//
// Configuration (Function App application settings):
//   ServiceBusConnection      Service Bus namespace connection string
//   TableStorageConnection    Storage account connection string
// =====================================================================

public class RfidEventConsumer
{
    private const string QueueName = "rfid-events";
    private const string TableName = "rfidevents";

    private readonly ILogger<RfidEventConsumer> _log;
    private readonly TableClient _table;

    public RfidEventConsumer(ILogger<RfidEventConsumer> log)
    {
        _log = log;

        // Resolve the storage connection from the app settings the portal
        // is responsible for providing. Failing fast here is intentional —
        // a misconfigured Function App should not silently appear healthy.
        var storageConn = Environment.GetEnvironmentVariable("TableStorageConnection")
            ?? throw new InvalidOperationException(
                "TableStorageConnection app setting is not set on this Function App.");

        _table = new TableClient(storageConn, TableName);

        // Create the table on first use. Cheap and idempotent — succeeds
        // whether the table exists or not. Removes a manual portal step.
        _table.CreateIfNotExists();
    }

    [Function(nameof(RfidEventConsumer))]
    public async Task Run(
        [ServiceBusTrigger(QueueName, Connection = "ServiceBusConnection")]
        string messageBody,
        FunctionContext context)
    {
        _log.LogInformation("Received message ({Length} bytes)", messageBody.Length);

        RfidEvent? evt;
        try
        {
            evt = JsonSerializer.Deserialize<RfidEvent>(messageBody);
        }
        catch (JsonException ex)
        {
            // A malformed message should not crash the function or trigger
            // endless retries. Log it and complete — Service Bus marks it
            // as delivered and moves on.
            _log.LogError(ex, "Failed to parse message JSON: {Body}", messageBody);
            return;
        }

        if (evt is null || string.IsNullOrEmpty(evt.EventId) || string.IsNullOrEmpty(evt.DeviceId))
        {
            _log.LogWarning("Message missing event_id or device_id; skipping. Body: {Body}", messageBody);
            return;
        }

        // Build the table entity. PartitionKey + RowKey are the two storage
        // keys; everything else is a regular column on the row.
        var entity = new TableEntity(evt.DeviceId, evt.EventId)
        {
            { "FirmwareVersion", evt.FirmwareVersion ?? "unknown" },
            { "Uid",             evt.Uid ?? "" },
            { "Valid",           evt.Valid },
            { "TsDeviceMs",      evt.TsDeviceMs },
            { "ReceivedAtUtc",   evt.ReceivedAtUtc?.ToUniversalTime() },
            { "ProcessedAtUtc",  DateTimeOffset.UtcNow }
        };

        try
        {
            // UpsertEntity with Replace mode means "create if absent,
            // overwrite if present". A retry of the same event_id writes
            // exactly the same row again — no duplicate, no error.
            await _table.UpsertEntityAsync(entity, TableUpdateMode.Replace);

            _log.LogInformation(
                "Wrote row: device={Device} event_id={EventId} uid={Uid} valid={Valid}",
                evt.DeviceId, evt.EventId, evt.Uid, evt.Valid);
        }
        catch (RequestFailedException ex)
        {
            // Re-throw so Service Bus retries the message — a transient
            // storage error should not result in a lost event. After the
            // queue's max delivery count, the message goes to the
            // dead-letter queue for inspection.
            _log.LogError(ex, "Failed to write row for event_id={EventId}", evt.EventId);
            throw;
        }
    }
}

// ---------------------------------------------------------------------
// Wire-format DTO. snake_case JSON to match the ingestor's output —
// both the Python ingestor and the C# ingestor publish snake_case, so
// the consumer sees identical bytes regardless of which language sent
// the message.
// ---------------------------------------------------------------------
public class RfidEvent
{
    [JsonPropertyName("event_id")]
    public string? EventId { get; set; }

    [JsonPropertyName("device_id")]
    public string? DeviceId { get; set; }

    [JsonPropertyName("firmware_version")]
    public string? FirmwareVersion { get; set; }

    [JsonPropertyName("uid")]
    public string? Uid { get; set; }

    [JsonPropertyName("valid")]
    public bool Valid { get; set; }

    [JsonPropertyName("ts_device_ms")]
    public long TsDeviceMs { get; set; }

    [JsonPropertyName("received_at_utc")]
    public DateTimeOffset? ReceivedAtUtc { get; set; }
}
