extern alias AzureIdentity;

using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Azure.AI.Extensions.OpenAI;
using Azure.Core;
using Microsoft.Teams.Apps;
using Microsoft.Teams.Core.Schema;
using OpenAI.Responses;
using Pizza.Contracts;

namespace PizzaKoordinator.Worker;

/// <summary>Invokes the Foundry Prompt Agent (Copilot harness) through its agent endpoint.</summary>
public sealed class FoundryAgent(KoordinatorOptions options, TokenCredential credential, IHttpClientFactory httpClientFactory)
{
    public async Task<(string ConversationId, string Text)> SendAsync(string? conversationId, string text, CancellationToken ct)
    {
        conversationId ??= await CreateConversationAsync(ct);
        try
        {
            return (conversationId, await RespondAsync(conversationId, text, ct));
        }
        catch (System.ClientModel.ClientResultException ex) when (ex.Status == 404)
        {
            conversationId = await CreateConversationAsync(ct);
            return (conversationId, await RespondAsync(conversationId, text, ct));
        }
    }

    private async Task<string> RespondAsync(string conversationId, string text, CancellationToken ct)
    {
        var client = new ProjectOpenAIClient(new Uri(options.FoundryEndpoint!), credential)
            .GetProjectResponsesClientForAgentEndpoint(options.FoundryAgentName, conversationId, options: new ProjectOpenAIClientOptions());
        var response = await client.CreateResponseAsync(
            new CreateResponseOptions { InputItems = { ResponseItem.CreateUserMessageItem(text) } }, ct);
        return FinalText(response.Value.OutputItems) ?? response.Value.GetOutputText();
    }

    /// <summary>The harness emits commentary messages between tool calls; only the last assistant message is the answer.</summary>
    internal static string? FinalText(IEnumerable<ResponseItem> items) =>
        items.OfType<MessageResponseItem>().LastOrDefault(m => m.Role == MessageRole.Assistant) is { } message
            ? string.Concat(message.Content.Select(c => c.Text)).Trim() is { Length: > 0 } text ? text : null
            : null;

    private async Task<string> CreateConversationAsync(CancellationToken ct)
    {
        using var request = await FoundryRest.RequestAsync(credential, HttpMethod.Post,
            $"{options.FoundryEndpoint!.TrimEnd('/')}/agents/{Uri.EscapeDataString(options.FoundryAgentName)}/endpoint/protocols/openai/conversations?api-version=v1", ct);
        request.Content = new StringContent("{}", Encoding.UTF8, "application/json");
        using var response = await httpClientFactory.CreateClient().SendAsync(request, ct);
        response.EnsureSuccessStatusCode();
        var body = await response.Content.ReadFromJsonAsync<JsonObject>(ct);
        return body?["id"]?.GetValue<string>() ?? throw new InvalidDataException("Foundry returned no conversation ID.");
    }
}

/// <summary>Reads and versions the courier-preferences skill, then rolls a new agent version onto it.</summary>
public sealed class FoundrySkills(KoordinatorOptions options, TokenCredential credential, IHttpClientFactory httpClientFactory)
{
    private const string SkillsFeature = "Skills=V1Preview";
    private string Project => options.FoundryEndpoint!.TrimEnd('/');
    private string Skill => Uri.EscapeDataString(options.PreferencesSkillName);

    public async Task<string> GetSkillMarkdownAsync(CancellationToken ct)
    {
        using var request = await FoundryRest.RequestAsync(credential, HttpMethod.Get, $"{Project}/skills/{Skill}/content?api-version=v1", ct, SkillsFeature);
        using var response = await SendAsync(request, ct);
        using var zip = new ZipArchive(await response.Content.ReadAsStreamAsync(ct));
        var entry = zip.Entries.FirstOrDefault(e => e.Name.Equals("SKILL.md", StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidDataException("Skill package has no SKILL.md.");
        using var reader = new StreamReader(entry.Open());
        return await reader.ReadToEndAsync(ct);
    }

    public async Task<string> PublishAsync(string markdown, CancellationToken ct)
    {
        using var request = await FoundryRest.RequestAsync(credential, HttpMethod.Post, $"{Project}/skills/{Skill}/versions?api-version=v1", ct, SkillsFeature);
        var file = new StringContent(markdown, Encoding.UTF8);
        file.Headers.ContentType = new MediaTypeHeaderValue("text/markdown");
        request.Content = new MultipartFormDataContent { { file, "files", "SKILL.md" }, { new StringContent("true"), "default" } };
        using var response = await SendAsync(request, ct);
        var body = await response.Content.ReadFromJsonAsync<JsonObject>(ct);
        return body?["version"]?.ToString() ?? throw new InvalidDataException("Foundry returned no skill version.");
    }

    // Agent versions store resolved skill versions, so a new agent version is required to pick up the new default.
    public async Task<string> RollAgentAsync(string skillVersion, CancellationToken ct)
    {
        var agentUrl = $"{Project}/agents/{Uri.EscapeDataString(options.FoundryAgentName)}";
        using var get = await FoundryRest.RequestAsync(credential, HttpMethod.Get, $"{agentUrl}?api-version=v1", ct, options.AgentFoundryFeatures);
        using var current = await SendAsync(get, ct);
        var latest = (await current.Content.ReadFromJsonAsync<JsonObject>(ct))?["versions"]?["latest"]
            ?? throw new InvalidDataException("Agent has no latest version.");
        var definition = latest["definition"]!.DeepClone();
        foreach (var skill in definition["skills"]?.AsArray() ?? [])
            if (skill?["name"]?.ToString() == options.PreferencesSkillName)
                skill["version"] = skillVersion;

        using var post = await FoundryRest.RequestAsync(credential, HttpMethod.Post, $"{agentUrl}/versions?api-version=v1", ct, options.AgentFoundryFeatures);
        post.Content = JsonContent.Create(new JsonObject
        {
            ["description"] = latest["description"]?.DeepClone(),
            ["metadata"] = latest["metadata"]?.DeepClone(),
            ["definition"] = definition
        });
        using var created = await SendAsync(post, ct);
        return (await created.Content.ReadFromJsonAsync<JsonObject>(ct))?["version"]?.ToString() ?? "?";
    }

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var response = await httpClientFactory.CreateClient().SendAsync(request, ct);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException($"Foundry {request.Method} {request.RequestUri?.AbsolutePath} failed: {(int)response.StatusCode} {await response.Content.ReadAsStringAsync(ct)}");
        return response;
    }
}

internal static class FoundryRest
{
    public static async Task<HttpRequestMessage> RequestAsync(TokenCredential credential, HttpMethod method, string url, CancellationToken ct, string? features = null)
    {
        var token = await credential.GetTokenAsync(new TokenRequestContext(["https://ai.azure.com/.default"]), ct);
        var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        if (features is not null) request.Headers.Add("Foundry-Features", features);
        return request;
    }
}

public sealed record CreatedEvent(string Id, string? OnlineMeetingUrl);

public interface IGraphClient
{
    Task<CreatedEvent> CreateEventAsync(ChannelIdentity identity, object graphEvent, CancellationToken ct);
    Task SendMailAsync(ChannelIdentity identity, string to, string subject, string body, CancellationToken ct);
    Task ReactAsync(ChannelIdentity identity, string messagePath, string reaction, CancellationToken ct);
}

/// <summary>Microsoft Graph as the PizzaKoordinator agentic user (calendar invites and mail).</summary>
public sealed class GraphClient(TeamsBotApplication teams, IHttpClientFactory httpClientFactory) : IGraphClient
{
    public async Task<CreatedEvent> CreateEventAsync(ChannelIdentity identity, object graphEvent, CancellationToken ct)
    {
        using var response = await SendAsync(identity, "/v1.0/me/events", graphEvent, ct);
        return await ReadCreatedEventAsync(response, ct);
    }

    internal static async Task<CreatedEvent> ReadCreatedEventAsync(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.StatusCode != HttpStatusCode.Created)
            throw new InvalidDataException($"Graph returned {(int)response.StatusCode} rather than a created event.");
        var body = await response.Content.ReadFromJsonAsync<JsonObject>(ct);
        if (body?["id"] is not JsonValue idValue || !idValue.TryGetValue<string>(out var id) || string.IsNullOrWhiteSpace(id))
            throw new InvalidDataException("Graph returned no event ID; verify the calendar before retrying.");
        return new CreatedEvent(id, (body["onlineMeeting"] as JsonObject)?["joinUrl"]?.ToString());
    }

    public async Task SendMailAsync(ChannelIdentity identity, string to, string subject, string body, CancellationToken ct)
    {
        using var _ = await SendAsync(identity, "/v1.0/me/sendMail", new
        {
            message = new
            {
                subject,
                body = new { contentType = "Text", content = body },
                toRecipients = new[] { new { emailAddress = new { address = to } } }
            },
            saveToSentItems = true
        }, ct);
    }

    public async Task ReactAsync(ChannelIdentity identity, string messagePath, string reaction, CancellationToken ct)
    {
        using var _ = await SendAsync(identity, $"/v1.0/{messagePath}/setReaction", new { reactionType = reaction }, ct);
    }

    private async Task<HttpResponseMessage> SendAsync(ChannelIdentity identity, string path, object payload, CancellationToken ct)
    {
        var token = await teams.GetAgenticGraphTokenAsync(JsonSerializer.Deserialize<AgenticIdentity>(identity.AgenticIdentity)!, ct);
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://graph.microsoft.com" + path) { Content = JsonContent.Create(payload) };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await httpClientFactory.CreateClient().SendAsync(request, ct);
        if (!response.IsSuccessStatusCode)
        {
            var status = response.StatusCode;
            var error = await response.Content.ReadAsStringAsync(ct);
            response.Dispose();
            throw new HttpRequestException($"Graph {path} failed: {(int)status} {error}", null, status);
        }
        return response;
    }
}

/// <summary>Typed client for the existing Pizza Orders API.</summary>
public sealed class OrdersClient(HttpClient http)
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { Converters = { new JsonStringEnumConverter() } };

    public async Task<IReadOnlyList<PizzaOrder>> GetNewAsync(CancellationToken ct) =>
        await http.GetFromJsonAsync<PizzaOrder[]>("api/orders/?status=New", Json, ct) ?? [];

    public async Task<PizzaOrder?> GetAsync(Guid id, CancellationToken ct)
    {
        using var response = await http.GetAsync($"api/orders/{id}", ct);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<PizzaOrder>(Json, ct);
    }

    /// <summary>The Orders API advances one step at a time, so walk the order through to Completed.</summary>
    public async Task<PizzaOrder?> CompleteAsync(Guid id, CancellationToken ct)
    {
        var order = await GetAsync(id, ct);
        while (order is { Status: not OrderStatus.Completed })
        {
            using var response = await http.PutAsJsonAsync($"api/orders/{id}/status",
                new UpdateOrderStatusRequest(order.Status + 1), Json, ct);
            response.EnsureSuccessStatusCode();
            order = await response.Content.ReadFromJsonAsync<PizzaOrder>(Json, ct);
        }
        return order;
    }
}

public static class TeamsCompatibility
{
    // Teams Apps 2.2.1 documents this API but does not expose it publicly (same workaround as mvp-pizzaops).
    public static async Task<string> GetAgenticGraphTokenAsync(this TeamsBotApplication application, AgenticIdentity identity, CancellationToken ct = default)
    {
        var method = typeof(TeamsBotApplication).GetMethod("GetAgenticGraphTokenAsync", BindingFlags.Instance | BindingFlags.NonPublic,
            binder: null, types: [typeof(AgenticIdentity), typeof(CancellationToken)], modifiers: null)
            ?? throw new MissingMethodException("The Teams SDK no longer exposes Agentic User Graph token acquisition.");
        return await (Task<string?>)method.Invoke(application, [identity, ct])!
            ?? throw new InvalidOperationException("The Teams SDK could not acquire an Agentic User Graph token.");
    }
}
