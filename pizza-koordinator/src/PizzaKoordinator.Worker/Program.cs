extern alias AzureIdentity;

using System.Text.Json;
using Azure.Core;
using Microsoft.Identity.Web;
using Microsoft.Teams.Apps;
using PizzaKoordinator.Worker;

// ACA Sandbox Worker behind Private Link. Only the DMZ Gateway's identity may call it.

var builder = WebApplication.CreateBuilder(args);

var options = builder.Configuration.GetSection(KoordinatorOptions.SectionName).Get<KoordinatorOptions>() ?? new();
var localBypass = builder.Environment.IsDevelopment() && options.AllowLocalAuthBypass;
if (!localBypass)
{
    var missing = new[] { (nameof(options.FoundryEndpoint), options.FoundryEndpoint), (nameof(options.OrdersApiUrl), options.OrdersApiUrl),
            (nameof(options.AllowedTenantId), options.AllowedTenantId), (nameof(options.ToolAudience), options.ToolAudience),
            (nameof(options.GatewayClientId), options.GatewayClientId), (nameof(options.AdminAadObjectId), options.AdminAadObjectId) }
        .Where(x => string.IsNullOrWhiteSpace(x.Item2)).Select(x => x.Item1).ToArray();
    if (missing.Length > 0 || options.Couriers.Count == 0)
        throw new InvalidOperationException($"PizzaKoordinator configuration is incomplete: {string.Join(", ", missing.Append(options.Couriers.Count == 0 ? "Couriers" : null).OfType<string>())}.");
}
builder.Configuration["ToolApi:Instance"] = "https://login.microsoftonline.com/";
builder.Configuration["ToolApi:ClientId"] = options.ToolAudience;
builder.Configuration["ToolApi:TenantId"] = options.AllowedTenantId;

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<TokenCredential>(new AzureIdentity::Azure.Identity.DefaultAzureCredential());
builder.Services.AddHttpClient();
builder.Services.AddHttpClient<OrdersClient>(http => http.BaseAddress = new Uri((options.OrdersApiUrl ?? "http://localhost:5000").TrimEnd('/') + "/"));
builder.Services.AddSingleton<CoordinatorState>();
builder.Services.AddSingleton<FoundryAgent>();
builder.Services.AddSingleton<FoundrySkills>();
builder.Services.AddSingleton<IGraphClient, GraphClient>();
builder.Services.AddSingleton<Coordinator>();
builder.Services.AddHostedService<OrderWatcher>();
builder.Services.AddSingleton<TeamsInbox>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<TeamsInbox>());
builder.Services.AddHealthChecks();
// Outbound only (replies, channel posts, agentic Graph tokens); Teams ingress lives in the Gateway.
builder.Services.AddTeamsBotApplication("AzureAd");
builder.Services.AddAuthentication().AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("ToolApi"), "Tools");
builder.Services.AddAuthorization(auth => auth.AddPolicy("gateway", policy =>
{
    if (localBypass) { policy.RequireAssertion(_ => true); return; }
    policy.AddAuthenticationSchemes("Tools").RequireAuthenticatedUser()
        .RequireAssertion(ctx => options.IsGatewayCaller(ctx.User));
}));

var app = builder.Build();
app.UseAuthorization();
app.MapHealthChecks("/health");

var gateway = app.MapGroup("").RequireAuthorization("gateway");
var inbox = app.Services.GetRequiredService<TeamsInbox>();
var state = app.Services.GetRequiredService<CoordinatorState>();
var coordinator = app.Services.GetRequiredService<Coordinator>();
gateway.MapPost("/internal/teams/activities", (JsonElement activity) =>
    inbox.TryEnqueue(activity) ? Results.Accepted() : Results.StatusCode(StatusCodes.Status503ServiceUnavailable));
gateway.MapGet("/v1/deliveries", () => state.Snapshot());
gateway.MapPost("/v1/deliveries/assign", (AssignRequest request, CancellationToken ct) => coordinator.AssignAsync(request, ct));
gateway.MapPost("/v1/deliveries/complete", (CompleteRequest request, CancellationToken ct) => coordinator.CompleteAsync(request, ct));
gateway.MapPost("/v1/meetings", (ScheduleMeetingRequest request, CancellationToken ct) => coordinator.ScheduleMeetingAsync(request, ct));
gateway.MapPost("/v1/preference-changes", (ProposeRequest request, CancellationToken ct) => coordinator.ProposeAsync(request, ct));

await app.RunAsync();
