using System.Net.Http.Headers;
using System.Text;
using Azure.Core;
using Azure.Identity;
using Microsoft.Identity.Web;
using Microsoft.Teams.Core.Hosting;
using PizzaKoordinator.Gateway;

// DMZ Gateway: the only public component. It authenticates Teams (Agent 365) and Foundry tool callers,
// holds no agent credentials, Graph/Foundry access or business logic, and forwards to the internal Worker
// with its own managed identity.
var builder = WebApplication.CreateBuilder(args);

var options = builder.Configuration.GetSection(GatewayOptions.SectionName).Get<GatewayOptions>() ?? new();
var localBypass = builder.Environment.IsDevelopment() && options.AllowLocalAuthBypass;
if (builder.Configuration.GetSection("AzureAd:ClientCredentials").Exists())
    throw new InvalidOperationException("The DMZ Gateway must not hold Agent Identity Blueprint credentials.");
if (!localBypass)
{
    var missing = new[] { (nameof(options.WorkerUrl), options.WorkerUrl), (nameof(options.AllowedTenantId), options.AllowedTenantId),
            (nameof(options.ToolAudience), options.ToolAudience), (nameof(options.FoundryClientId), options.FoundryClientId),
            ("AzureAd:ClientId", builder.Configuration["AzureAd:ClientId"]) }
        .Where(x => string.IsNullOrWhiteSpace(x.Item2)).Select(x => x.Item1).ToArray();
    if (missing.Length > 0)
        throw new InvalidOperationException($"Gateway configuration is incomplete: {string.Join(", ", missing)}.");
}
builder.Configuration["ToolApi:Instance"] = "https://login.microsoftonline.com/";
builder.Configuration["ToolApi:ClientId"] = options.ToolAudience;
builder.Configuration["ToolApi:TenantId"] = options.AllowedTenantId;

builder.Services.AddHttpClient("worker", http => http.BaseAddress = new Uri((options.WorkerUrl ?? "http://localhost:5080").TrimEnd('/') + "/"));
builder.Services.AddHealthChecks();
// Inbound Teams token validation only: without ClientCredentials the Gateway cannot act as the agent.
builder.Services.AddBotApplication("AzureAd");
builder.Services.AddAuthentication().AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("ToolApi"), "Tools");
builder.Services.AddAuthorization(auth => auth.AddPolicy("foundry", policy =>
{
    if (localBypass) { policy.RequireAssertion(_ => true); return; }
    policy.AddAuthenticationSchemes("Tools").RequireAuthenticatedUser()
        .RequireAssertion(ctx => options.IsFoundryCaller(ctx.User));
}));

var app = builder.Build();
TokenCredential credential = new DefaultAzureCredential();
var workerScope = new TokenRequestContext([$"api://{options.ToolAudience}/.default"]);
var workers = app.Services.GetRequiredService<IHttpClientFactory>();

async Task<HttpResponseMessage> ForwardAsync(HttpRequestMessage request, CancellationToken ct)
{
    if (!localBypass)
        request.Headers.Authorization = new("Bearer", (await credential.GetTokenAsync(workerScope, ct)).Token);
    return await workers.CreateClient("worker").SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
}

app.MapHealthChecks("/health");
app.MapGet("/health/ready", async (CancellationToken ct) =>
{
    using var request = new HttpRequestMessage(HttpMethod.Get, "v1/deliveries");
    using var response = await ForwardAsync(request, ct);
    response.EnsureSuccessStatusCode();
    return Results.Text("Healthy");
});

// Teams -> Worker: forward message activities only; a non-success Worker answer surfaces as 500 so Teams retries.
app.UseBotApplication("api/messages").OnActivity = async (activity, ct) =>
{
    if (!string.Equals(activity.Type, "message", StringComparison.OrdinalIgnoreCase)) return;
    using var request = new HttpRequestMessage(HttpMethod.Post, "internal/teams/activities")
    {
        Content = new StringContent(activity.ToJson(), Encoding.UTF8, "application/json")
    };
    using var response = await ForwardAsync(request, ct);
    response.EnsureSuccessStatusCode();
};

// Foundry OpenAPI tools -> Worker: authenticated reverse proxy for /v1 only.
app.Map("/v1/{**path}", async (HttpContext context, string? path) =>
{
    using var request = new HttpRequestMessage(new HttpMethod(context.Request.Method), $"v1/{path}{context.Request.QueryString}");
    if (context.Request.ContentLength > 0 || context.Request.Headers.TransferEncoding.Count > 0)
    {
        request.Content = new StreamContent(context.Request.Body);
        if (context.Request.ContentType is { } contentType) request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
    }
    using var response = await ForwardAsync(request, context.RequestAborted);
    context.Response.StatusCode = (int)response.StatusCode;
    if (response.Content.Headers.ContentType is { } responseType) context.Response.ContentType = responseType.ToString();
    await response.Content.CopyToAsync(context.Response.Body, context.RequestAborted);
}).RequireAuthorization("foundry");

await app.RunAsync();
