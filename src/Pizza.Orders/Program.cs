using Pizza.Orders.Components;
using Pizza.Orders.Data;
using Pizza.Contracts;
using Pizza.Orders.Services;
using Microsoft.AspNetCore.RateLimiting;
using System.Text.Json.Serialization;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddRazorComponents().AddInteractiveServerComponents();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddHealthChecks();
builder.Services.AddSingleton(new PriceDisplay(builder.Configuration["Pizza:CurrencyCode"]));
builder.Services.AddSingleton(new ServiceLinks(builder.Configuration["Pizza:CatalogUrl"], builder.Environment.IsDevelopment()));
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));
builder.Services.AddRateLimiter(options =>
{
    options.AddPolicy("pizza-api", context =>
        RateLimitPartition.GetFixedWindowLimiter(
            context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 120,
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0,
                AutoReplenishment = true
            }));
});

var storageMode = builder.Configuration["Pizza:StorageMode"]
    ?? Environment.GetEnvironmentVariable("PIZZA_STORAGE_MODE")
    ?? (builder.Environment.IsDevelopment() ? "memory" : "azure");

if (string.Equals(storageMode, "memory", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddSingleton<IOrderStore, InMemoryOrderStore>();
}
else if (string.Equals(storageMode, "azure", StringComparison.OrdinalIgnoreCase))
{
    var connectionString = builder.Configuration["Pizza:Azure:SqlConnectionString"]
        ?? throw new InvalidOperationException("Pizza:Azure:SqlConnectionString is required.");
    builder.Services.AddSingleton<IOrderStore>(new SqlOrderStore(connectionString));
}
else
{
    throw new InvalidOperationException(
        $"Unsupported Pizza:StorageMode '{storageMode}'. Use 'memory' or 'azure'.");
}

builder.Services.AddSingleton<OrderService>();
var catalogUrl = builder.Configuration["Pizza:CatalogUrl"]
    ?? throw new InvalidOperationException("Pizza:CatalogUrl is required; Orders reads the separate Catalog API.");
if (!Uri.TryCreate(catalogUrl, UriKind.Absolute, out var catalogUri) ||
    (catalogUri.Scheme != Uri.UriSchemeHttps && !(builder.Environment.IsDevelopment() && catalogUri.IsLoopback)))
{
    throw new InvalidOperationException("Pizza:CatalogUrl must be HTTPS (or loopback HTTP in Development).");
}

builder.Services.AddHttpClient("catalog", client =>
{
    client.BaseAddress = new Uri(catalogUri.AbsoluteUri.TrimEnd('/') + "/");
    client.Timeout = TimeSpan.FromSeconds(60);
});
builder.Services.AddSingleton<IPizzaCatalogReader, HttpPizzaCatalogClient>();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    app.UseHsts();
}

app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);
app.UseHttpsRedirection();
app.UseAntiforgery();
app.UseRateLimiter();
app.MapStaticAssets();
app.MapHealthChecks("/health/ready");
app.MapPizzaApi();
app.MapRazorComponents<App>().AddInteractiveServerRenderMode();

app.Run();

public partial class Program;
