using System.Text.Json;
using Microsoft.Teams.Apps;
using Microsoft.Teams.Core.Schema;

namespace PizzaOps.Api.Services;

public sealed class TeamsGateway(TeamsBotApplication application) : ITeamsGateway
{
    public TenantIdentity CaptureIdentity(object activity)
    {
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(activity));
        var root = document.RootElement;
        var conversationId = GetProperty(root, "conversation", "id");
        var tenantId = GetProperty(root, "channelData", "tenant", "id");
        var aadObjectId = GetProperty(root, "from", "aadObjectId");
        var serviceUrl = GetProperty(root, "serviceUrl");
        var agenticIdentity = JsonSerializer.Deserialize<ChannelAccount>(root.GetProperty("recipient").GetRawText())?
            .GetAgenticIdentity()
            ?? throw new InvalidDataException("Teams activity has no Agentic Identity on its recipient.");
        return new TenantIdentity(
            tenantId,
            aadObjectId,
            conversationId,
            serviceUrl,
            JsonSerializer.Serialize(agenticIdentity));
    }

    public Task SendProactiveAsync(TenantIdentity identity, string text, CancellationToken cancellationToken) =>
        application.SendAsync(
            identity.ConversationId,
            text,
            new Uri(identity.ServiceUrl),
            JsonSerializer.Deserialize<AgenticIdentity>(identity.AgenticIdentity)!,
            cancellationToken);

    private static string GetProperty(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
            if (!current.TryGetProperty(segment, out current))
                throw new InvalidDataException($"Teams activity is missing {string.Join('.', path)}.");
        return current.GetString() ?? throw new InvalidDataException($"Teams activity has no value for {string.Join('.', path)}.");
    }
}
