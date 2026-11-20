using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Teams.Apps;
using Microsoft.Teams.Core.Schema;
using Pizza.Contracts;

namespace PizzaKoordinator.Api;

public sealed record Sender(string? AadObjectId, string? Name, string ConversationType);
public sealed record AssignRequest(Guid OrderId, string Courier, string DeliveryStart, int DurationMinutes = 30);
public sealed record CompleteRequest(Guid OrderId, string Courier);
public sealed record ProposeRequest(string Courier, string Summary, string UpdatedSkillMarkdown);

/// <summary>Glue between Teams, the Foundry agent and the deterministic actions the agent may take via tools.</summary>
public sealed class Coordinator(
    KoordinatorOptions options,
    CoordinatorState state,
    FoundryAgent agent,
    FoundrySkills skills,
    GraphClient graph,
    OrdersClient orders,
    TeamsBotApplication teams,
    TimeProvider time,
    ILogger<Coordinator> logger)
{
    private readonly SemaphoreSlim _turn = new(1, 1);
    private readonly TimeZoneInfo _zone = TimeZoneInfo.FindSystemTimeZoneById(options.TimeZone);

    public string Now => TimeZoneInfo.ConvertTime(time.GetUtcNow(), _zone).ToString("dddd yyyy-MM-dd HH:mm", CultureInfo.GetCultureInfo("cs-CZ"));

    public Sender Capture(object activity)
    {
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(activity));
        var root = document.RootElement;
        var identity = JsonSerializer.Deserialize<ChannelAccount>(root.GetProperty("recipient").GetRawText())?.GetAgenticIdentity()
            ?? throw new InvalidDataException("Teams activity has no Agentic Identity on its recipient.");
        var type = Get(root, "conversation", "conversationType") ?? "";
        if (type == "channel" || state.Channel is null)
            state.Channel = new ChannelIdentity(
                Get(root, "channelData", "tenant", "id") ?? "",
                Get(root, "conversation", "id") ?? throw new InvalidDataException("Teams activity has no conversation."),
                Get(root, "serviceUrl") ?? throw new InvalidDataException("Teams activity has no serviceUrl."),
                JsonSerializer.Serialize(identity));
        return new Sender(Get(root, "from", "aadObjectId"), Get(root, "from", "name"), type);
    }

    public async Task<string> AskAsync(string prompt, CancellationToken ct)
    {
        await _turn.WaitAsync(ct);
        try
        {
            var (conversationId, text) = await agent.SendAsync(state.ConversationId, $"Aktualni cas: {Now} ({options.TimeZone})\n{prompt}", ct);
            state.ConversationId = conversationId;
            return text;
        }
        finally { _turn.Release(); }
    }

    public async Task PostAsync(string text, CancellationToken ct)
    {
        var channel = state.Channel ?? throw new InvalidOperationException("PizzaKoordinator is not bound to a Teams channel yet.");
        var root = channel.ConversationId.Split(";messageid=")[0];
        await teams.SendAsync(root, text, new Uri(channel.ServiceUrl), JsonSerializer.Deserialize<AgenticIdentity>(channel.AgenticIdentity)!, ct);
    }

    public async Task AnnounceAsync(PizzaOrder order, CancellationToken ct) =>
        await PostAsync(await AskAsync($"""
            NOVA_OBJEDNAVKA
            {Describe(order)}
            Napis zpravu do kanalu, ktera kuryry vyzve ke koordinaci rozvozu a doporuc vhodneho kuryra podle preferenci.
            """, ct), ct);

    public async Task UrgeAsync(TrackedOrder tracked, CancellationToken ct)
    {
        var order = await orders.GetAsync(tracked.OrderId, ct);
        if (order is null or { Status: OrderStatus.Completed }) { state.Forget(tracked.OrderId); return; }
        await PostAsync(await AskAsync($"""
            URGENCE c. {tracked.Urges}
            Na objednavku nikdo z kuryru nereagoval {options.UrgeAfterMinutes} minuty.
            {Describe(order)}
            Napis kratkou urgenci kuryrum do kanalu.
            """, ct), ct);
    }

    public async Task<IResult> AssignAsync(AssignRequest request, CancellationToken ct)
    {
        var courier = options.FindCourier(request.Courier);
        if (courier is null) return Results.BadRequest($"Neznamy kuryr '{request.Courier}'. Povoleni: {string.Join(", ", options.Couriers.Select(c => c.Name))}.");
        if (!TryParseLocal(request.DeliveryStart, out var start)) return Results.BadRequest("deliveryStart musi byt datum a cas, napr. 2025-01-31T18:30.");
        if (state.Channel is not { } channel) return Results.Conflict("Agent jeste neni pripojeny do Teams kanalu.");
        var order = await orders.GetAsync(request.OrderId, ct);
        if (order is null) return Results.NotFound("Objednavka neexistuje.");
        if (order.Status == OrderStatus.Completed) return Results.Conflict("Objednavka uz je dokoncena.");

        var holder = state.TryAssign(order.Id, courier.Name);
        if (holder is not null)
            return string.Equals(holder, courier.Name, StringComparison.OrdinalIgnoreCase)
                ? Results.Ok(new { order.Id, courier = holder, alreadyAssigned = true })
                : Results.Conflict($"Objednavku uz rozvazi {holder}.");
        try
        {
            var end = start.AddMinutes(Math.Clamp(request.DurationMinutes, 5, 240));
            var eventId = await graph.CreateEventAsync(channel, new
            {
                subject = $"Rozvoz pizzy - objednavka {Short(order.Id)}",
                body = new { contentType = "Text", content = Describe(order) },
                start = new { dateTime = start.UtcDateTime.ToString("s"), timeZone = "UTC" },
                end = new { dateTime = end.UtcDateTime.ToString("s"), timeZone = "UTC" },
                location = new { displayName = order.Customer.Address },
                attendees = new[] { new { emailAddress = new { address = courier.Email, name = courier.Name }, type = "required" } }
            }, ct);
            state.Get(order.Id)!.EventId = eventId;
            await graph.SendMailAsync(channel, options.AdminEmail, $"PizzaKoordinator: {courier.Name} rozveze objednavku {Short(order.Id)}",
                $"Kuryr: {courier.Name} ({courier.Email})\nCas: {Local(start)} - {Local(end):HH:mm}\n\n{Describe(order)}", ct);
            return Results.Ok(new { order.Id, courier = courier.Name, start = Local(start), end = Local(end), invitationSent = true, adminNotified = true });
        }
        catch (Exception ex)
        {
            state.Unassign(order.Id);
            logger.LogError(ex, "Assigning order {OrderId} to {Courier} failed", order.Id, courier.Name);
            return Results.Problem($"Prirazeni selhalo: {ex.Message}");
        }
    }

    public async Task<IResult> CompleteAsync(CompleteRequest request, CancellationToken ct)
    {
        var tracked = state.Get(request.OrderId);
        if (tracked?.Courier is null) return Results.Conflict("Objednavka neni prirazena zadnemu kuryrovi.");
        if (!string.Equals(tracked.Courier, request.Courier?.Trim(), StringComparison.OrdinalIgnoreCase))
            return Results.Conflict($"Objednavku rozvazi {tracked.Courier}, ne {request.Courier}.");
        var order = await orders.CompleteAsync(request.OrderId, ct);
        if (order is null) return Results.NotFound("Objednavka neexistuje.");
        state.Forget(order.Id);
        return Results.Ok(new { order.Id, status = order.Status.ToString() });
    }

    public async Task<IResult> ProposeAsync(ProposeRequest request, CancellationToken ct)
    {
        var courier = options.FindCourier(request.Courier);
        if (courier is null) return Results.BadRequest($"Neznamy kuryr '{request.Courier}'.");
        if (!request.UpdatedSkillMarkdown.Contains($"name: {options.PreferencesSkillName}"))
            return Results.BadRequest($"updatedSkillMarkdown musi byt kompletni SKILL.md vcetne front matter 'name: {options.PreferencesSkillName}'.");
        var diff = TextDiff.Lines(await skills.GetSkillMarkdownAsync(ct), request.UpdatedSkillMarkdown);
        if (diff.Length == 0) return Results.BadRequest("Navrh neobsahuje zadnou zmenu.");

        var change = state.AddChange(courier.Name, request.Summary, request.UpdatedSkillMarkdown, diff);
        var text = $"""
            Zadost o zmenu preferenci kuryra {courier.Name} (ID {change.Id}): {request.Summary}

            Navrhovane zmeny skillu {options.PreferencesSkillName}:
            {diff}

            Admin ({options.AdminEmail}) schvali zpravou "@PizzaKoordinator schvaluji {change.Id}" nebo zamitne "@PizzaKoordinator zamitam {change.Id}".
            """;
        await PostAsync(text, ct);
        if (state.Channel is { } channel)
            await graph.SendMailAsync(channel, options.AdminEmail, $"PizzaKoordinator: schvaleni zmeny preferenci {courier.Name} ({change.Id})", text, ct);
        return Results.Ok(new { change.Id, status = "ceka na schvaleni adminem", diff });
    }

    /// <summary>Deterministic admin decision; never routed through the LLM.</summary>
    public async Task<string> DecideAsync(Sender sender, bool approve, string id, CancellationToken ct)
    {
        if (!options.IsAdmin(sender.AadObjectId)) return $"Zmenu preferenci muze schvalit nebo zamitnout jen admin ({options.AdminEmail}).";
        if (!state.TryTakeChange(id, out var change)) return $"Zadost {id} neexistuje nebo uz byla vyrizena.";
        if (!approve) return $"Zmena preferenci {change.Courier} ({id}) byla zamitnuta. Skill zustava beze zmeny.";
        try
        {
            var skillVersion = await skills.PublishAsync(change.NewSkill, ct);
            try
            {
                var agentVersion = await skills.RollAgentAsync(skillVersion, ct);
                return $"Schvaleno. Skill {options.PreferencesSkillName} v{skillVersion}, agent v{agentVersion}. Nove preference kuryra {change.Courier} plati.";
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Agent version refresh failed after publishing skill version {Version}", skillVersion);
                return $"Schvaleno a skill v{skillVersion} je vychozi verze, ale novou verzi agenta se nepodarilo vytvorit ({ex.Message}). Spustte znovu Deploy-FoundryAgent.ps1.";
            }
        }
        catch (Exception ex)
        {
            state.RestoreChange(change);
            logger.LogError(ex, "Publishing preference change {Id} failed", id);
            return $"Publikace zmeny {id} selhala: {ex.Message}. Zadost zustava k vyrizeni.";
        }
    }

    public static string Describe(PizzaOrder order)
    {
        var text = new StringBuilder()
            .AppendLine($"Objednavka: {order.Id} (kratce {Short(order.Id)})")
            .AppendLine($"Zakaznik: {order.Customer.Name}")
            .AppendLine($"Adresa: {order.Customer.Address}")
            .AppendLine($"Vytvoreno: {order.CreatedAt:u}");
        foreach (var line in order.Items) text.AppendLine($"- {line.Quantity}x {line.PizzaName}");
        return text.Append($"Celkem: {order.Total}").ToString();
    }

    private static string Short(Guid id) => id.ToString("N")[..8];

    private string Local(DateTimeOffset value) => TimeZoneInfo.ConvertTime(value, _zone).ToString("yyyy-MM-dd HH:mm");

    private bool TryParseLocal(string value, out DateTimeOffset result)
    {
        result = default;
        if (!DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)) return false;
        // Without an explicit offset the agent means coordinator-local time.
        result = DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var withOffset) && HasOffset(value)
            ? withOffset
            : new DateTimeOffset(DateTime.SpecifyKind(parsed, DateTimeKind.Unspecified), _zone.GetUtcOffset(parsed));
        return true;
    }

    private static bool HasOffset(string value) =>
        value.EndsWith('Z') || value.EndsWith('z') || System.Text.RegularExpressions.Regex.IsMatch(value, @"[+-]\d{2}:?\d{2}$");

    private static string? Get(JsonElement root, params string[] path)
    {
        foreach (var segment in path)
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty(segment, out root)) return null;
        return root.ValueKind == JsonValueKind.String ? root.GetString() : null;
    }
}
