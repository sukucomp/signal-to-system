using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

// Standard isolated-worker host bootstrap for an Azure Function App that
// uses a Service Bus trigger (no ASP.NET Core HTTP integration needed).
//
// ConfigureFunctionsWorkerDefaults wires up the Functions runtime; the two
// service registrations enable Application Insights so log lines from the
// function show up in the App Insights instance created with the Function App.
var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        services.AddApplicationInsightsTelemetryWorkerService();
        services.ConfigureFunctionsApplicationInsights();
    })
    .Build();

host.Run();
