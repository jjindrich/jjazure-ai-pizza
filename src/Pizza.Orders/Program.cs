using Pizza.Orders.Components;
using Pizza.Orders.Data;
using Pizza.Contracts;
using Pizza.Orders.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using Microsoft.AspNetCore.RateLimiting;
using ModelContextProtocol.AspNetCore;
using System.Text.Json.Serialization;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
var agentMcpOptions = builder.Configuration.GetSection(OrdersAgentMcpOptions.SectionName)
    .Get<OrdersAgentMcpOptions>() ?? new();
var agentMcpEnabled = agentMcpOptions.IsConfigured;

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
var authentication = builder.Services.AddAuthentication(options =>
{
    if (agentMcpEnabled)
    {
        options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
        options.DefaultChallengeScheme = JwtBearerDefaults.AuthenticationScheme;
    }
});
builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("orders-agent-mcp", policy =>
        policy.AddAuthenticationSchemes(JwtBearerDefaults.AuthenticationScheme)
            .RequireAuthenticatedUser()
            .RequireAssertion(context => agentMcpOptions.Allows(context.User)));
});
if (agentMcpEnabled)
{
    authentication.AddJwtBearer(options =>
    {
        options.Authority = $"https://login.microsoftonline.com/{agentMcpOptions.TenantId}/v2.0";
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidAudiences = agentMcpOptions.ValidAudiences(),
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true
        };
    });
    builder.Services.AddMcpServer()
        .WithHttpTransport(options => options.SessionMode = HttpServerSessionMode.Stateless)
        .WithTools<OrdersMcpTools>();
}

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
if (!agentMcpEnabled)
{
    app.Use(async (context, next) =>
    {
        if (context.Request.Path == "/mcp")
        {
            context.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }

        await next();
    });
}
app.UseAuthentication();
app.UseAuthorization();

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
if (agentMcpEnabled)
{
    app.MapMcp("/mcp")
        .RequireAuthorization("orders-agent-mcp")
        .RequireRateLimiting("pizza-api");
}
else
{
    app.Logger.LogWarning("Orders MCP endpoint is disabled because Pizza:AgentMcp is not fully configured.");
}
app.MapRazorComponents<App>().AddInteractiveServerRenderMode();

app.Run();

public partial class Program;
