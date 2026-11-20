extern alias AzureIdentity;

using Azure.Core;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Cosmos;
using Microsoft.Teams.Apps;
using PizzaOps.Api;
using PizzaOps.Api.Services;
using PizzaOps.Api.Storage;
using PizzaOps.Api.Security;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

var builder = WebApplication.CreateBuilder(args);

var options = new PizzaOpsOptions();
builder.Configuration.GetSection(PizzaOpsOptions.SectionName).Bind(options);
var apiOptions = new ApiOptions();
builder.Configuration.GetSection(ApiOptions.SectionName).Bind(apiOptions);
ValidateConfiguration(options, apiOptions, builder.Environment);
builder.Configuration["ToolApi:Instance"] = "https://login.microsoftonline.com/";
builder.Configuration["ToolApi:ClientId"] = apiOptions.Audience;
builder.Configuration["ToolApi:TenantId"] = options.AllowedTenantId;

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(apiOptions);
builder.Services.AddOpenApi("v1");
builder.Services.AddHealthChecks();
builder.Services.AddHttpClient();
builder.Services.AddApplicationInsightsTelemetry();
builder.Services.ConfigureHttpJsonOptions(json =>
    json.SerializerOptions.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase)));
builder.Services.AddAuthentication()
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("ToolApi"), "PizzaOpsTools");
builder.Services.AddSingleton<IToolAuthorization, ToolAuthorizationPolicy>();
builder.Services.AddTransient<ToolAuthorizationMiddleware>();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<IPolicyService, PolicyService>();
builder.Services.AddSingleton<IDeliveryPlanner, DeliveryPlanner>();
builder.Services.AddTeamsBotApplication("AzureAd");

if (options.AllowLocalFallbacks)
{
    builder.Services.AddSingleton<ITaskStore, InMemoryTaskStore>();
    builder.Services.AddSingleton<IWakeupScheduler, InMemoryWakeupScheduler>();
    builder.Services.AddSingleton<IFoundryBridge, LocalFoundryBridge>();
    builder.Services.AddSingleton<ITeamsGateway, LocalTeamsGateway>();
    builder.Services.AddSingleton<IGraphCalendarClient, LocalGraphCalendarClient>();
}
else
{
    var credential = new AzureIdentity::Azure.Identity.DefaultAzureCredential();
    builder.Services.AddSingleton<TokenCredential>(credential);
    builder.Services.AddSingleton(_ => new CosmosClient(options.CosmosEndpoint, credential));
    builder.Services.AddSingleton<ITaskStore, CosmosTaskStore>();
    builder.Services.AddSingleton(_ => new ServiceBusClient(
        options.ServiceBusNamespace!, credential));
    builder.Services.AddSingleton(provider => provider.GetRequiredService<ServiceBusClient>()
        .CreateSender(options.ServiceBusQueue));
    builder.Services.AddSingleton(provider => provider.GetRequiredService<ServiceBusClient>()
        .CreateProcessor(options.ServiceBusQueue, new ServiceBusProcessorOptions
        {
            AutoCompleteMessages = false,
            MaxConcurrentCalls = 1
        }));
    builder.Services.AddSingleton<IWakeupScheduler, ServiceBusWakeupScheduler>();
    builder.Services.AddHostedService<WakeupWorker>();
    builder.Services.AddSingleton<IFoundryBridge, FoundryBridge>();
    builder.Services.AddSingleton<ITeamsGateway, TeamsGateway>();
    builder.Services.AddSingleton<IGraphCalendarClient, GraphCalendarClient>();
}

var app = builder.Build();
app.UseMiddleware<ToolAuthorizationMiddleware>();
app.MapHealthChecks("/health").ExcludeFromDescription();
app.MapOpenApi("/openapi/v1.json");
app.MapPizzaOps();
app.UseTeamsBotApplication("api/messages");

var teamsApplication = app.Services.GetRequiredService<TeamsBotApplication>();
teamsApplication.OnMessage(async (context, cancellationToken) =>
{
    var store = app.Services.GetRequiredService<ITaskStore>();
    var identity = app.Services.GetRequiredService<ITeamsGateway>().CaptureIdentity(context.Activity);
    var activityId = context.Activity.Id ?? Guid.NewGuid().ToString("N");
    if (!await store.TryCreateIdempotencyAsync(
        identity.TenantId, $"teams-{activityId}", "teams-activity", cancellationToken))
        return;

    var task = await store.GetByTeamsConversationIdAsync(identity.TenantId, identity.ConversationId, cancellationToken);
    if (task is null)
    {
        task = await store.CreateAsync(new DurableTask
        {
            Id = $"teams-{activityId}",
            TenantId = identity.TenantId,
            Title = "Inbound Teams Agentic User activity",
            Description = context.Activity.Text,
            State = TaskState.Running,
            Identity = identity,
            OwnerAadObjectId = identity.AadObjectId,
            TeamsConversationId = identity.ConversationId
        }, cancellationToken);
    }

    var text = context.Activity.Text ?? "";
    var foundry = app.Services.GetRequiredService<IFoundryBridge>();
    var turn = await foundry.SendAsync(
        identity,
        task.FoundryConversationId,
        $"Active durable PizzaOps task ID: {task.Id}. Tenant ID: {identity.TenantId}.\nUser message: {text}",
        cancellationToken);
    task.FoundryConversationId = turn.ConversationId;
    task.Description = text;
    await store.UpdateAsync(task, task.ETag!, cancellationToken);
    await context.SendAsync(turn.Text, cancellationToken);
});

await app.RunAsync();

static void ValidateConfiguration(PizzaOpsOptions options, ApiOptions api, IHostEnvironment environment)
{
    if (environment.IsDevelopment() && options.AllowLocalFallbacks) return;
    var missing = new List<string>();
    AddIfMissing(nameof(options.FoundryEndpoint), options.FoundryEndpoint, missing);
    AddIfMissing(nameof(options.FoundryAgentName), options.FoundryAgentName, missing);
    AddIfMissing(nameof(options.CosmosEndpoint), options.CosmosEndpoint, missing);
    AddIfMissing(nameof(options.CosmosDatabase), options.CosmosDatabase, missing);
    AddIfMissing(nameof(options.CosmosTasksContainer), options.CosmosTasksContainer, missing);
    AddIfMissing(nameof(options.CosmosEventsContainer), options.CosmosEventsContainer, missing);
    AddIfMissing(nameof(options.ServiceBusNamespace), options.ServiceBusNamespace, missing);
    AddIfMissing(nameof(options.ServiceBusQueue), options.ServiceBusQueue, missing);
    AddIfMissing(nameof(options.GraphWebhookClientState), options.GraphWebhookClientState, missing);
    AddIfMissing("Api:Audience", api.Audience, missing);
    AddIfMissing("Api:AllowedClientId", api.AllowedClientId, missing);
    AddIfMissing(nameof(options.AllowedIssuers), options.AllowedIssuers, missing);
    AddIfMissing(nameof(options.AllowedTenantId), options.AllowedTenantId, missing);
    if (missing.Count > 0)
        throw new InvalidOperationException($"PizzaOps production configuration is incomplete: {string.Join(", ", missing)}.");
}

static void AddIfMissing(string name, string? value, List<string> missing)
{
    if (string.IsNullOrWhiteSpace(value)) missing.Add(name);
}
