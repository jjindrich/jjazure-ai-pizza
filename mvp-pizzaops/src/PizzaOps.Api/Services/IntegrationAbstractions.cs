extern alias AzureIdentity;

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Azure;
using Azure.AI.Extensions.OpenAI;
using Microsoft.Teams.Apps;
using Microsoft.Teams.Core.Schema;
using OpenAI.Responses;

namespace PizzaOps.Api.Services;

public interface IGraphCalendarClient
{
    Task<object> AvailabilityAsync(TenantIdentity identity, CalendarAvailabilityRequest request, CancellationToken cancellationToken);
    Task<object> CreateEventAsync(TenantIdentity identity, CalendarEventRequest request, CancellationToken cancellationToken);
    Task<object> UpdateEventAsync(TenantIdentity identity, string eventId, CalendarEventRequest request, CancellationToken cancellationToken);
}

public interface IFoundryBridge
{
    Task<FoundryTurn> SendAsync(TenantIdentity identity, string? conversationId, string text, CancellationToken cancellationToken);
    Task<FoundryTurn> ContinueAsync(TenantIdentity identity, string conversationId, string taskId, string prompt, CancellationToken cancellationToken);
}

public interface ITeamsGateway
{
    TenantIdentity CaptureIdentity(object activity);
    Task SendProactiveAsync(TenantIdentity identity, string text, CancellationToken cancellationToken);
}

public interface IWakeupScheduler
{
    Task<string> ScheduleAsync(string tenantId, string taskId, DateTimeOffset wakeAt, string prompt, string idempotencyKey, CancellationToken cancellationToken);
    bool IsPastDue(DateTimeOffset wakeAt, DateTimeOffset now);
}

public sealed class GraphCalendarClient(
    TeamsBotApplication teams,
    IHttpClientFactory httpClientFactory) : IGraphCalendarClient
{
    public Task<object> AvailabilityAsync(TenantIdentity identity, CalendarAvailabilityRequest request, CancellationToken cancellationToken) =>
        SendGraphAsync(identity, HttpMethod.Post, "/v1.0/me/calendar/getSchedule", new
        {
            schedules = new[] { "me" },
            startTime = new { dateTime = request.Start.DateTime, timeZone = request.TimeZone },
            endTime = new { dateTime = request.End.DateTime, timeZone = request.TimeZone },
            availabilityViewInterval = request.DurationMinutes
        }, cancellationToken);

    public Task<object> CreateEventAsync(TenantIdentity identity, CalendarEventRequest request, CancellationToken cancellationToken) =>
        SendGraphAsync(identity, HttpMethod.Post, "/v1.0/me/events", ToGraphEvent(request), cancellationToken);

    public Task<object> UpdateEventAsync(TenantIdentity identity, string eventId, CalendarEventRequest request, CancellationToken cancellationToken) =>
        SendGraphAsync(identity, HttpMethod.Patch, $"/v1.0/me/events/{Uri.EscapeDataString(eventId)}", ToGraphEvent(request), cancellationToken);

    private static object ToGraphEvent(CalendarEventRequest request) => new
    {
        subject = request.Subject,
        start = new { dateTime = request.Start.DateTime, timeZone = request.TimeZone },
        end = new { dateTime = request.End.DateTime, timeZone = request.TimeZone },
        attendees = request.Attendees.Select(address => new
        {
            emailAddress = new { address },
            type = "required"
        })
    };

    private async Task<object> SendGraphAsync(TenantIdentity identity, HttpMethod method, string path, object payload, CancellationToken cancellationToken)
    {
        var token = await teams.GetAgenticGraphTokenAsync(
            JsonSerializer.Deserialize<AgenticIdentity>(identity.AgenticIdentity)!, cancellationToken);
        using var request = new HttpRequestMessage(method, "https://graph.microsoft.com" + path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
        using var response = await httpClientFactory.CreateClient().SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        return JsonSerializer.Deserialize<object>(await response.Content.ReadAsStringAsync(cancellationToken))!;
    }
}

public sealed class FoundryBridge(
    PizzaOpsOptions options,
    Azure.Core.TokenCredential credential,
    IHttpClientFactory httpClientFactory) : IFoundryBridge
{
    private ProjectOpenAIClient Client => new(new Uri(options.FoundryEndpoint!), credential);

    public Task<FoundryTurn> SendAsync(TenantIdentity identity, string? conversationId, string text, CancellationToken cancellationToken) =>
        RunAsync(conversationId, text, cancellationToken);

    public Task<FoundryTurn> ContinueAsync(TenantIdentity identity, string conversationId, string taskId, string prompt, CancellationToken cancellationToken) =>
        RunAsync(conversationId, $"PizzaOps task {taskId}: {prompt}", cancellationToken);

    private async Task<FoundryTurn> RunAsync(string? conversationId, string text, CancellationToken cancellationToken)
    {
#pragma warning disable OPENAI001
        conversationId = string.IsNullOrWhiteSpace(conversationId)
            ? await CreateAgentConversationAsync(cancellationToken)
            : conversationId;
        try
        {
            return await CreateAgentResponseAsync(conversationId, text, cancellationToken);
        }
        catch (System.ClientModel.ClientResultException ex) when (ex.Status == 404)
        {
            conversationId = await CreateAgentConversationAsync(cancellationToken);
            return await CreateAgentResponseAsync(conversationId, text, cancellationToken);
        }
    }

    private async Task<FoundryTurn> CreateAgentResponseAsync(
        string conversationId, string text, CancellationToken cancellationToken)
    {
        var client = Client.GetProjectResponsesClientForAgentEndpoint(
            options.FoundryAgentName!,
            conversationId,
            options: new ProjectOpenAIClientOptions());
#pragma warning restore OPENAI001
        var response = await client.CreateResponseAsync(
            new CreateResponseOptions
            {
                InputItems = { ResponseItem.CreateUserMessageItem(text) }
            },
            cancellationToken);
        return new(conversationId, response.Value.GetOutputText());
    }

    private async Task<string> CreateAgentConversationAsync(CancellationToken cancellationToken)
    {
        var token = await credential.GetTokenAsync(
            new Azure.Core.TokenRequestContext(["https://ai.azure.com/.default"]),
            cancellationToken);
        var uri = $"{options.FoundryEndpoint!.TrimEnd('/')}/agents/" +
                  $"{Uri.EscapeDataString(options.FoundryAgentName!)}/endpoint/protocols/openai/conversations" +
                  "?api-version=v1";
        using var request = new HttpRequestMessage(HttpMethod.Post, uri)
        {
            Content = new StringContent("{}", Encoding.UTF8, "application/json")
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        using var response = await httpClientFactory.CreateClient().SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(
            await response.Content.ReadAsStringAsync(cancellationToken));
        return document.RootElement.GetProperty("id").GetString()
            ?? throw new InvalidDataException("Foundry conversation creation returned no ID.");
    }
}
