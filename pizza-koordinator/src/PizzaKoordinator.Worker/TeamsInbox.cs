using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Channels;

namespace PizzaKoordinator.Worker;

/// <summary>Internal processing of Teams messages that the DMZ Gateway has already authenticated and forwarded.</summary>
public sealed partial class TeamsInbox(
    Coordinator coordinator,
    CoordinatorState state,
    KoordinatorOptions options,
    IGraphClient graph,
    ILogger<TeamsInbox> logger) : BackgroundService
{
    private const string SeenReaction = "👀";
    private readonly Channel<JsonElement> _queue = Channel.CreateBounded<JsonElement>(new BoundedChannelOptions(100) { SingleReader = true });

    public bool TryEnqueue(JsonElement activity) => _queue.Writer.TryWrite(activity.Clone());

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var activity in _queue.Reader.ReadAllAsync(stoppingToken))
        {
            try { await HandleAsync(activity, stoppingToken); }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested)
            {
                logger.LogError(ex, "Processing a forwarded Teams activity failed");
            }
        }
    }

    public async Task HandleAsync(JsonElement activity, CancellationToken ct)
    {
        if (!activity.TryGetProperty("type", out var type) || type.GetString() != "message") return;
        var inbound = coordinator.Capture(activity);
        var text = Mention().Replace(inbound.Text ?? "", "").Trim();
        if (text.Length == 0) return;
        await MarkSeenAsync(activity, inbound, ct);

        if (Decision().Match(text) is { Success: true } match)
        {
            var approve = match.Groups[1].Value.StartsWith("schval", StringComparison.OrdinalIgnoreCase)
                || match.Groups[1].Value.StartsWith("approve", StringComparison.OrdinalIgnoreCase);
            await coordinator.ReplyAsync(inbound.Reply, await coordinator.DecideAsync(inbound.Sender, approve, match.Groups[2].Value, ct), ct);
            return;
        }

        var sender = inbound.Sender;
        var courier = options.FindSender(sender.AadObjectId, sender.Name);
        if (courier is not null) state.CourierActivity();
        var role = courier is not null ? $"kuryr {courier.Name}" : options.IsAdmin(sender.AadObjectId) ? "admin" : "jiny uzivatel";
        await coordinator.ReplyAsync(inbound.Reply, await coordinator.AskAsync($"""
            ZPRAVA_Z_TEAMS
            Odesilatel: {sender.Name} (role: {role})
            Text: {text}
            """, ct), ct);
    }

    private async Task MarkSeenAsync(JsonElement activity, Inbound inbound, CancellationToken ct)
    {
        if (MessagePath(activity) is not { } path) return;
        try { await graph.ReactAsync(inbound.Reply, path, SeenReaction, ct); }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            logger.LogWarning(ex, "Marking the Teams message as seen failed");
        }
    }

    /// <summary>Graph path of the inbound Teams message: a chat message, channel post or channel reply.</summary>
    internal static string? MessagePath(JsonElement activity)
    {
        var messageId = Get(activity, "id");
        var conversation = Get(activity, "conversation", "id");
        if (messageId is null || conversation is null) return null;
        Func<string, string> e = Uri.EscapeDataString;
        if (Get(activity, "conversation", "conversationType") != "channel")
            return $"chats/{e(conversation)}/messages/{e(messageId)}";

        var team = Get(activity, "channelData", "team", "aadGroupId");
        var channel = Get(activity, "channelData", "channel", "id");
        if (team is null || channel is null) return null;
        var parts = conversation.Split(";messageid=");
        var root = parts.Length > 1 ? parts[1] : messageId;
        var post = $"teams/{e(team)}/channels/{e(channel)}/messages/{e(root)}";
        return root == messageId ? post : $"{post}/replies/{e(messageId)}";
    }

    private static string? Get(JsonElement element, params string[] path)
    {
        foreach (var name in path)
            if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out element)) return null;
        return element.ValueKind == JsonValueKind.String ? element.GetString() : null;
    }

    [GeneratedRegex(@"\b(schval\w*|approve\w*|zamit\w*|reject\w*)\s+([0-9a-f]{6})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Decision();

    [GeneratedRegex("<at>.*?</at>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex Mention();
}
