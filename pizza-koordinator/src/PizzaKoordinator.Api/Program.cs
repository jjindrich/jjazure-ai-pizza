extern alias AzureIdentity;

using System.Text.RegularExpressions;
using Azure.Core;
using Microsoft.Identity.Web;
using Microsoft.Teams.Apps;
using PizzaKoordinator.Api;

var builder = WebApplication.CreateBuilder(args);

var options = builder.Configuration.GetSection(KoordinatorOptions.SectionName).Get<KoordinatorOptions>() ?? new();
var localBypass = builder.Environment.IsDevelopment() && options.AllowLocalAuthBypass;
if (!localBypass)
{
    var missing = new[] { (nameof(options.FoundryEndpoint), options.FoundryEndpoint), (nameof(options.OrdersApiUrl), options.OrdersApiUrl),
            (nameof(options.AllowedTenantId), options.AllowedTenantId), (nameof(options.ToolAudience), options.ToolAudience),
            (nameof(options.ToolClientId), options.ToolClientId), (nameof(options.AdminAadObjectId), options.AdminAadObjectId) }
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
builder.Services.AddSingleton<GraphClient>();
builder.Services.AddSingleton<Coordinator>();
builder.Services.AddHostedService<OrderWatcher>();
builder.Services.AddHealthChecks();
builder.Services.AddTeamsBotApplication("AzureAd");
builder.Services.AddAuthentication().AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("ToolApi"), "Tools");
builder.Services.AddAuthorization(auth => auth.AddPolicy("tools", policy =>
{
    if (localBypass) { policy.RequireAssertion(_ => true); return; }
    policy.AddAuthenticationSchemes("Tools").RequireAuthenticatedUser()
        .RequireAssertion(ctx =>
            ctx.User.FindFirst("tid")?.Value == options.AllowedTenantId &&
            (ctx.User.FindFirst("azp") ?? ctx.User.FindFirst("appid"))?.Value == options.ToolClientId);
}));

var app = builder.Build();
app.UseAuthorization();
app.MapHealthChecks("/health");
app.UseTeamsBotApplication("api/messages");

var tools = app.MapGroup("/v1").RequireAuthorization("tools");
var state = app.Services.GetRequiredService<CoordinatorState>();
var coordinator = app.Services.GetRequiredService<Coordinator>();
tools.MapGet("/deliveries", () => state.Snapshot());
tools.MapPost("/deliveries/assign", (AssignRequest request, CancellationToken ct) => coordinator.AssignAsync(request, ct));
tools.MapPost("/deliveries/complete", (CompleteRequest request, CancellationToken ct) => coordinator.CompleteAsync(request, ct));
tools.MapPost("/preference-changes", (ProposeRequest request, CancellationToken ct) => coordinator.ProposeAsync(request, ct));

var decision = new Regex(@"\b(schval\w*|approve\w*|zamit\w*|reject\w*)\s+([0-9a-f]{6})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
var mention = new Regex("<at>.*?</at>", RegexOptions.IgnoreCase | RegexOptions.Singleline);
app.Services.GetRequiredService<TeamsBotApplication>().OnMessage(async (context, ct) =>
{
    var sender = coordinator.Capture(context.Activity);
    var text = mention.Replace(context.Activity.Text ?? "", "").Trim();
    if (text.Length == 0) return;

    if (decision.Match(text) is { Success: true } match)
    {
        var approve = match.Groups[1].Value.StartsWith("schval", StringComparison.OrdinalIgnoreCase)
            || match.Groups[1].Value.StartsWith("approve", StringComparison.OrdinalIgnoreCase);
        await context.SendAsync(await coordinator.DecideAsync(sender, approve, match.Groups[2].Value, ct), ct);
        return;
    }

    var courier = options.FindSender(sender.AadObjectId, sender.Name);
    if (courier is not null) state.CourierActivity();
    var role = courier is not null ? $"kuryr {courier.Name}" : options.IsAdmin(sender.AadObjectId) ? "admin" : "jiny uzivatel";
    await context.SendAsync(await coordinator.AskAsync($"""
        ZPRAVA_Z_TEAMS
        Odesilatel: {sender.Name} (role: {role})
        Text: {text}
        """, ct), ct);
});

await app.RunAsync();
