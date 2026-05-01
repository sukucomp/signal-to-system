using System;
using System.IO.Ports;
using System.Text.Json;
using System.Text.Json.Serialization;

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
                        // Ignore timeout (same as Python continue)
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

        if (data == null || data.Uid == null)
            throw new Exception("Invalid payload");

        return new RfidEvent
        {
            Uid = data.Uid,
            Valid = data.Valid,
            TimeUtc = DateTime.UtcNow
        };
    }

    static void PrintEvent(RfidEvent ev)
    {
        Console.WriteLine("PARSED EVENT:");
        Console.WriteLine($"UID   : {ev.Uid}");
        Console.WriteLine($"Valid : {ev.Valid}");
        Console.WriteLine($"Time  : {ev.TimeUtc:o}");
        Console.WriteLine();
    }
}

class RfidPayload
{
    [JsonPropertyName("uid")]
    public string? Uid { get; set; }

    [JsonPropertyName("valid")]
    public bool Valid { get; set; }
}

class RfidEvent
{
    public string? Uid { get; set; }
    public bool Valid { get; set; }
    public DateTime TimeUtc { get; set; }
}
