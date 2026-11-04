using Microsoft.AspNetCore.RateLimiting;
using Pizza.Catalog.Components;
using Pizza.Catalog.Data;
using Pizza.Catalog.Services;
using Pizza.Contracts;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddRazorComponents().AddInteractiveServerComponents();
builder.Services.AddHealthChecks();
builder.Services.AddRateLimiter(options =>
    options.AddPolicy("pizza-api", context =>
        RateLimitPartition.GetFixedWindowLimiter(
            context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 120,
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0,
                AutoReplenishment = true
            })));

var storageMode = builder.Configuration["Pizza:StorageMode"]
    ?? Environment.GetEnvironmentVariable("PIZZA_STORAGE_MODE")
    ?? (builder.Environment.IsDevelopment() ? "memory" : "azure");
if (string.Equals(storageMode, "memory", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddSingleton<IPizzaCatalogStore, InMemoryPizzaCatalogStore>();
    builder.Services.AddSingleton<IPizzaImageStore, LocalPizzaImageStore>();
}
else if (string.Equals(storageMode, "azure", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddAzurePizzaStorage(builder.Configuration);
}
else
{
    throw new InvalidOperationException($"Unsupported Pizza:StorageMode '{storageMode}'. Use 'memory' or 'azure'.");
}

builder.Services.AddSingleton<PizzaCatalogService>();
builder.Services.AddHostedService<CatalogSeedService>();
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
