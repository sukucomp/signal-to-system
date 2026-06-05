using System;
using System.IO.Ports;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using Azure.Messaging.ServiceBus;

// =====================================================================
// RFID serial ingestor (C# / .NET).
//
// Reads EVENT:{...} lines from a serial-connected microcontroller,
// validates the fleet-ready schema, prints parsed events, and publishes
// each event to an Azure Service Bus queue. The Service Bus MessageId is
// set to the event's event_id so duplicate detection on the queue
// catches infrastructure retries automatically.
//
// Schema:
//   {
//     "event_id":         "<uuid>",
//     "device_id":        "reader-NN",
//     "firmware_version": "1.x.0",
//     "uid":              "AA BB CC DD",
//     "valid":            true | false,
//     "ts_device_ms":     <int>
//   }
//
// The host adds ReceivedAtUtc on ingestion. Downstream stages will add
// further timestamps on subsequent hops.
//
// Configuration:
//   SERVICEBUS_CONNECTION_STRING   environment variable, required when publishing
//   --port NAME                    serial port (default: COM3)
//   --baud N                       baud rate (default: 9600)
//   --queue NAME                   queue name (default: rfid-events)
//   --no-publish                   listen-only mode; skip Service Bus entirely
//
// NuGet:
//   dotnet add package Azure.Messaging.ServiceBus
//   dotnet add package System.IO.Ports
// =====================================================================

class Program
{
    private const string EVENT_PREFIX = "EVENT:";

    static async Task<int> Main(string[] args)
    {
        // Minimal arg parsing — kept single-file so the project doesn't
        // need System.CommandLine (still preview as of net8) for four flags.
        var options = ParseArgs(args);

        Console.WriteLine($"Opening {options.Port} at {options.Baud} baud...");

        // Decide on Service Bus configuration up front. Failing fast at
        // startup on a missing connection string is much friendlier than
        // producing per-event publish failures every time a card is scanned.
        string? connectionString = null;
        if (!options.NoPublish)
        {
            connectionString = Environment.GetEnvironmentVariable("SERVICEBUS_CONNECTION_STRING");
            if (string.IsNullOrEmpty(connectionString))
            {
                Console.WriteLine(
                    "ERROR: SERVICEBUS_CONNECTION_STRING environment variable is not set.\n" +
                    "       Either set it (see README) or pass --no-publish to run in\n" +
                    "       listen-only mode."
                );
                return 2;
            }
        }

        try
        {
            using var serial = new SerialPort(options.Port, options.Baud);
            serial.ReadTimeout = 2000;
            serial.Open();

            Console.WriteLine($"Connected to {options.Port}");

            if (connectionString == null)
            {
                Console.WriteLine("Service Bus publishing disabled (--no-publish)");
                return RunReadLoop(serial, sender: null);
            }

            // Open one client + sender for the lifetime of the process.
            // Per-event opens would add a TCP+AMQP handshake to every scan
            // — wasteful and visibly slower in a screen recording.
            await using var client = new ServiceBusClient(connectionString);
            await using var sender = client.CreateSender(options.Queue);

            Console.WriteLine($"Publishing to Service Bus queue: {options.Queue}");
            return RunReadLoop(serial, sender);
        }
        catch (Exception ex) when (ex.Message.Contains("port") || ex is UnauthorizedAccessException)
        {
            Console.WriteLine($"Failed to open serial port: {ex.Message}");
            Console.WriteLine("Check the COM port number and make sure no other app is using the serial port.");
            return 1;
        }
    }

    static int RunReadLoop(SerialPort serial, ServiceBusSender? sender)
    {
        Console.WriteLine("Listening for RFID events...");

        while (true)
        {
            try
            {
                string? line = serial.ReadLine()?.Trim();

                if (string.IsNullOrEmpty(line))
                    continue;

                var eventObj = ParseEvent(line);

                if (eventObj == null)
                {
                    Console.WriteLine($"RAW: {line}");
                    continue;
                }

                Console.WriteLine($"RAW: {line}");
                PrintEvent(eventObj);

                if (sender != null)
                {
                    // Each publish is awaited synchronously here. The serial
                    // read is sync, so a fully async loop would buy nothing
                    // in this single-reader prototype. Once the local buffer
                    // arrives in a later iteration, the await chain becomes
                    // more interesting.
                    PublishEvent(sender, eventObj).GetAwaiter().GetResult();
                }
            }
            catch (TimeoutException)
            {
                // Serial read timeout — same as Python's `if not raw_bytes: continue`.
            }
            catch (JsonException ex)
            {
                Console.WriteLine($"JSON parse error: {ex.Message}");
            }
            catch (Exception ex)
            {
                // Resilience: log and keep the loop alive. A single bad event
                // should never take down the listener. Narrow this once the
                // observability post adds structured logging.
                Console.WriteLine($"Unexpected error: {ex.Message}");
            }
        }
    }

    // -----------------------------------------------------------------
    // Publish one event to Service Bus. Sets MessageId = event_id so
    // duplicate detection on the queue can collapse infrastructure
    // retries (vs distinct user-initiated taps, which carry distinct
    // event_ids and are correctly preserved as separate events).
    //
    // Failure handling is deliberately minimal for this iteration —
    // log and return. The local buffer-and-retry layer that handles
    // offline operation is a separate, larger change.
    // -----------------------------------------------------------------
    static async Task PublishEvent(ServiceBusSender sender, RfidEvent ev)
    {
        try
        {
            string body = JsonSerializer.Serialize(ev, JsonOpts);
            var msg = new ServiceBusMessage(body)
            {
                MessageId = ev.EventId
            };
            await sender.SendMessageAsync(msg);
            Console.WriteLine($"  Published   : event_id={ev.EventId}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"  Publish FAILED: {ex.GetType().Name}: {ex.Message}");
        }
    }

    // Reused JSON options for outbound serialization. snake_case to match
    // the wire format the Python ingestor produces and the queue/consumer
    // contract. Without this, serialization would emit PascalCase property
    // names and break cross-language consumers.
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        WriteIndented = false
    };

    static RfidEvent? ParseEvent(string line)
    {
        if (!line.StartsWith(EVENT_PREFIX))
            return null;

        string payload = line.Substring(EVENT_PREFIX.Length);

        var data = JsonSerializer.Deserialize<RfidPayload>(payload);

        if (data == null)
            throw new Exception("Empty payload");

        // Hard-required fields. Missing these is a malformed event.
        if (data.Uid == null)
            throw new Exception("Missing required field: uid");

        // Soft-required: if the device is pre-schema, fill in host-side
        // defaults so downstream stages still get a usable event. Mirrors
        // the fallback behaviour in the Python ingestor.
        string eventId = data.EventId ?? Guid.NewGuid().ToString();
        string deviceId = data.DeviceId ?? "unknown";
        string firmwareVersion = data.FirmwareVersion ?? "unknown";

        return new RfidEvent
        {
            EventId = eventId,
            DeviceId = deviceId,
            FirmwareVersion = firmwareVersion,
            Uid = data.Uid,
            Valid = data.Valid,
            TsDeviceMs = data.TsDeviceMs,
            ReceivedAtUtc = DateTime.UtcNow
        };
    }

    static string FormatDeviceMs(long ms)
    {
        // Render millis()-since-boot as a human-readable uptime string.
        // The raw ms value stays in the event object; only display changes.
        // Example: 20341 -> "20.341s (uptime 0:00:20)"
        double secondsTotal = ms / 1000.0;
        long totalSeconds = ms / 1000;
        long hours = totalSeconds / 3600;
        long minutes = (totalSeconds % 3600) / 60;
        long seconds = totalSeconds % 60;
        return $"{secondsTotal:F3}s (uptime {hours}:{minutes:D2}:{seconds:D2})";
    }

    static void PrintEvent(RfidEvent ev)
    {
        Console.WriteLine("PARSED EVENT:");
        Console.WriteLine($"  Event ID    : {ev.EventId}");
        Console.WriteLine($"  Device ID   : {ev.DeviceId}");
        Console.WriteLine($"  Firmware    : {ev.FirmwareVersion}");
        Console.WriteLine($"  UID         : {ev.Uid}");
        Console.WriteLine($"  Valid       : {ev.Valid}");
        Console.WriteLine($"  Since boot  : {FormatDeviceMs(ev.TsDeviceMs)}");
        Console.WriteLine($"  Received at : {ev.ReceivedAtUtc:o}");
    }

    // -----------------------------------------------------------------
    // Tiny manual arg parser. Recognises:
    //   --port NAME, --baud N, --queue NAME, --no-publish
    // Anything unrecognised is silently ignored. Adequate for four flags;
    // graduate to System.CommandLine when the surface grows.
    // -----------------------------------------------------------------
    static IngestorOptions ParseArgs(string[] args)
    {
        var options = new IngestorOptions();
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--port" when i + 1 < args.Length:
                    options.Port = args[++i];
                    break;
                case "--baud" when i + 1 < args.Length:
                    if (int.TryParse(args[++i], out int b)) options.Baud = b;
                    break;
                case "--queue" when i + 1 < args.Length:
                    options.Queue = args[++i];
                    break;
                case "--no-publish":
                    options.NoPublish = true;
                    break;
            }
        }
        return options;
    }
}

class IngestorOptions
{
    public string Port { get; set; } = "COM3";
    public int Baud { get; set; } = 9600;
    public string Queue { get; set; } = "rfid-events";
    public bool NoPublish { get; set; } = false;
}

class RfidPayload
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
}

class RfidEvent
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
    public DateTime ReceivedAtUtc { get; set; }
}
