using System;
using System.IO.Ports;
using System.Text.Json;
using System.Text.Json.Serialization;

// =====================================================================
// RFID serial ingestor (C# / .NET).
//
// Mirrors the Python ingestor: reads EVENT:{...} lines from a serial port
// and parses the fleet-ready schema:
//
//   {
//     "event_id":         "<uuid>",
//     "device_id":        "reader-NN",
//     "firmware_version": "1.1.0",
//     "uid":              "AA BB CC DD",
//     "valid":            true | false,
//     "ts_device_ms":     <int>
//   }
//
// The host adds ReceivedAtUtc on ingestion. Downstream stages will add
// further timestamps on subsequent hops.
// =====================================================================

class Program
{
    private const string EVENT_PREFIX = "EVENT:";

    static void Main(string[] args)
    {
        string port = "COM3";
        int baud = 9600;

        Console.WriteLine($"Opening {port} at {baud} baud...");

        try
        {
            using (SerialPort serial = new SerialPort(port, baud))
            {
                serial.ReadTimeout = 2000;
                serial.Open();

                Console.WriteLine($"Connected to {port}");
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
                    }
                    catch (TimeoutException)
                    {
                        // Ignore timeout (matches Python continue behaviour).
                    }
                    catch (JsonException ex)
                    {
                        Console.WriteLine($"JSON parse error: {ex.Message}");
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"Unexpected error: {ex.Message}");
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to open port: {ex.Message}");
        }
    }

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
        Console.WriteLine();
    }
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
    public string? EventId { get; set; }
    public string? DeviceId { get; set; }
    public string? FirmwareVersion { get; set; }
    public string? Uid { get; set; }
    public bool Valid { get; set; }
    public long TsDeviceMs { get; set; }
    public DateTime ReceivedAtUtc { get; set; }
}
