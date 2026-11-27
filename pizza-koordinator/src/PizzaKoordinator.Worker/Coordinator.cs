using System.Globalization;
using System.Net;
using System.Net.Mail;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Teams.Apps;
using Microsoft.Teams.Core.Schema;
using Pizza.Contracts;

namespace PizzaKoordinator.Worker;

public sealed record Sender(string? AadObjectId, string? Name, string ConversationType);
public sealed record Inbound(Sender Sender, string? Type, string? Text, ChannelIdentity Reply);
public sealed record AssignRequest(Guid OrderId, string Courier, string DeliveryStart, int DurationMinutes = 30);
public sealed record CompleteRequest(Guid OrderId, string Courier);
public sealed record ScheduleMeetingRequest(string Subject, string Start, int DurationMinutes, string[] Attendees,
    string? Location = null, string? Description = null, bool IsOnline = false);
public sealed record ProposeRequest(string Courier, string Summary, string UpdatedSkillMarkdown);

/// <summary>Glue between Teams, the Foundry agent and the deterministic actions the agent may take via tools.</summary>
public sealed class Coordinator(
    KoordinatorOptions options,
    CoordinatorState state,
    FoundryAgent agent,
    FoundrySkills skills,
    IGraphClient graph,
    OrdersClient orders,
    TeamsBotApplication teams,
    TimeProvider time,
    ILogger<Coordinator> logger)
{
    private readonly SemaphoreSlim _turn = new(1, 1);
    private readonly TimeZoneInfo _zone = TimeZoneInfo.FindSystemTimeZoneById(options.TimeZone);

    public string Now => TimeZoneInfo.ConvertTime(time.GetUtcNow(), _zone).ToString("dddd yyyy-MM-dd HH:mm", CultureInfo.GetCultureInfo("cs-CZ"));

    /// <summary>Reads an activity forwarded by the Gateway and binds the coordination channel.</summary>
    public Inbound Capture(JsonElement root)
    {
        var channelId = Get(root, "channelId");
        var type = Get(root, "conversation", "conversationType") ?? "";
        logger.LogInformation("Received activity from channel {ChannelId} with conversation type {ConversationType}",
            channelId ?? "(missing)", type);
        var identity = root.GetProperty("recipient").Deserialize<ChannelAccount>()?.GetAgenticIdentity()
            ?? throw new InvalidDataException("Teams activity has no Agentic Identity on its recipient.");
        var reply = new ChannelIdentity(
            Get(root, "channelData", "tenant", "id") ?? "",
            Get(root, "conversation", "id") ?? throw new InvalidDataException("Teams activity has no conversation."),
            Get(root, "serviceUrl") ?? throw new InvalidDataException("Teams activity has no serviceUrl."),
            JsonSerializer.Serialize(identity));
        if (string.Equals(channelId, "msteams", StringComparison.OrdinalIgnoreCase) &&
            (string.Equals(type, "channel", StringComparison.OrdinalIgnoreCase) || state.Channel is null))
            state.Channel = reply;
        return new Inbound(new Sender(Get(root, "from", "aadObjectId"), Get(root, "from", "name"), type), Get(root, "type"), Get(root, "text"), reply);
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
        await ReplyAsync(channel with { ConversationId = channel.ConversationId.Split(";messageid=")[0] }, text, ct);
    }

    /// <summary>Sends to the exact conversation; an inbound channel id keeps its ";messageid=" thread.</summary>
    public async Task ReplyAsync(ChannelIdentity conversation, string text, CancellationToken ct) =>
        await teams.SendAsync(conversation.ConversationId, text, new Uri(conversation.ServiceUrl),
            JsonSerializer.Deserialize<AgenticIdentity>(conversation.AgenticIdentity)!, ct);

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
        {
            if (!string.Equals(holder, courier.Name, StringComparison.OrdinalIgnoreCase))
                return Results.Conflict($"Objednavku uz rozvazi {holder}.");
            var existing = state.Get(order.Id)!;
            return existing.EventId is not null
                ? Results.Ok(new { order.Id, courier = holder, alreadyAssigned = true, invitationSent = true, adminNotified = existing.AdminNotified })
                : Results.Conflict("Prirazeni se zpracovava nebo stav pozvanky neni znam; pred opakovanim overte kalendar agenta.");
        }
        try
        {
            var end = start.AddMinutes(Math.Clamp(request.DurationMinutes, 5, 240));
            var calendarEvent = await graph.CreateEventAsync(channel, new
            {
                subject = $"Rozvoz pizzy - objednavka {Short(order.Id)}",
                body = new { contentType = "Text", content = Describe(order) },
                start = new { dateTime = start.UtcDateTime.ToString("s"), timeZone = "UTC" },
                end = new { dateTime = end.UtcDateTime.ToString("s"), timeZone = "UTC" },
                location = new { displayName = order.Customer.Address },
                attendees = new[] { new { emailAddress = new { address = courier.Email, name = courier.Name }, type = "required" } }
            }, ct);
            state.Get(order.Id)!.EventId = calendarEvent.Id;
            await graph.SendMailAsync(channel, options.AdminEmail, $"Pizza Koordinator: {courier.Name} rozveze objednavku {Short(order.Id)}",
                $"Kuryr: {courier.Name} ({courier.Email})\nCas: {Local(start)} - {Local(end):HH:mm}\n\n{Describe(order)}", ct);
            state.Get(order.Id)!.AdminNotified = true;
            return Results.Ok(new { order.Id, courier = courier.Name, start = Local(start), end = Local(end), invitationSent = true, adminNotified = true });
        }
        catch (Exception ex) when (!ct.IsCancellationRequested && ex is (HttpRequestException or InvalidDataException or JsonException or TaskCanceledException))
        {
            var tracked = state.Get(order.Id)!;
            if (tracked.EventId is null && ex is HttpRequestException { StatusCode: HttpStatusCode.BadRequest or
                HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden or HttpStatusCode.NotFound or HttpStatusCode.UnprocessableEntity })
                state.Unassign(order.Id);
            logger.LogError(ex, "Assigning order {OrderId} to {Courier} failed", order.Id, courier.Name);
            return Results.Problem(tracked.EventId is not null
                ? "Pozvanka byla vytvorena, ale odeslani e-mailu adminovi nelze potvrdit. Prirazeni neopakujte."
                : "Stav pozvanky nelze potvrdit. Pred opakovanim overte kalendar agenta.", statusCode: 502);
        }
    }

    public async Task<IResult> ScheduleMeetingAsync(ScheduleMeetingRequest request, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Subject))
            return Results.BadRequest("Je potreba predmet schuzky.");
        if (string.IsNullOrWhiteSpace(request.Start) ||
            !System.Text.RegularExpressions.Regex.IsMatch(request.Start, @"\d{1,2}:\d{2}") ||
            !TryParseLocal(request.Start, out var start))
            return Results.BadRequest("Je potreba platne datum a cas zacatku; pri zmene casu uvedte casovy offset.");
        if (request.DurationMinutes <= 0)
            return Results.BadRequest("Delka schuzky musi byt kladny pocet minut.");
        if (request.Attendees is null || request.Attendees.Length == 0)
            return Results.BadRequest("Je potreba alespon jeden ucastnik s e-mailovou adresou.");

        var emails = new List<string>();
        foreach (var attendee in request.Attendees)
        {
            var value = attendee?.Trim();
            if (string.IsNullOrEmpty(value) || !MailAddress.TryCreate(value, out var address) ||
                !value.Contains('@') || !string.Equals(address.Address, value, StringComparison.OrdinalIgnoreCase))
                return Results.BadRequest("Kazdy ucastnik musi mit platnou e-mailovou adresu.");
            if (!emails.Contains(value, StringComparer.OrdinalIgnoreCase)) emails.Add(value);
        }
        emails.Sort(StringComparer.OrdinalIgnoreCase);
        DateTimeOffset end;
        try { end = start.AddMinutes(request.DurationMinutes); }
        catch (ArgumentOutOfRangeException) { return Results.BadRequest("Delka schuzky presahuje platny casovy rozsah."); }
        if (state.Channel is not { } channel)
            return Results.Conflict("Agent jeste nema navazanou Teams identitu pro pristup ke kalendari.");

        var subject = request.Subject.Trim();
        var location = string.IsNullOrWhiteSpace(request.Location) ? null : request.Location.Trim();
        var description = string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim();
        var fingerprint = JsonSerializer.SerializeToUtf8Bytes(new
        {
            subject,
            start = start.UtcDateTime.ToString("O", CultureInfo.InvariantCulture),
            request.DurationMinutes,
            location,
            description,
            attendees = emails.Select(x => x.ToLowerInvariant()).Order(StringComparer.Ordinal).ToArray(),
            request.IsOnline
        });
        var attendees = new JsonArray();
        foreach (var email in emails)
            attendees.Add(new JsonObject { ["emailAddress"] = new JsonObject { ["address"] = email }, ["type"] = "required" });
        var graphEvent = new JsonObject
        {
            ["subject"] = subject,
            ["start"] = new JsonObject { ["dateTime"] = start.UtcDateTime.ToString("s"), ["timeZone"] = "UTC" },
            ["end"] = new JsonObject { ["dateTime"] = end.UtcDateTime.ToString("s"), ["timeZone"] = "UTC" },
            ["attendees"] = attendees,
            ["transactionId"] = new Guid(SHA256.HashData(fingerprint).AsSpan(0, 16)).ToString()
        };
        if (!string.IsNullOrEmpty(location)) graphEvent["location"] = new JsonObject { ["displayName"] = location };
        if (!string.IsNullOrEmpty(description)) graphEvent["body"] = new JsonObject { ["contentType"] = "Text", ["content"] = description };
        if (request.IsOnline)
        {
            graphEvent["isOnlineMeeting"] = true;
            graphEvent["onlineMeetingProvider"] = "teamsForBusiness";
        }

        try
        {
            var created = await graph.CreateEventAsync(channel, graphEvent, ct);
            return Results.Ok(new
            {
                created = true,
                eventId = created.Id,
                invitationsSubmitted = true,
                deliveryVerified = false,
                onlineMeetingUrl = created.OnlineMeetingUrl,
                warning = request.IsOnline && string.IsNullOrWhiteSpace(created.OnlineMeetingUrl)
                    ? "Udalost byla vytvorena, ale Teams odkaz nebyl potvrzen. Pred opakovanim overte kalendar."
                    : null
            });
        }
        catch (Exception ex) when (!ct.IsCancellationRequested && ex is (HttpRequestException or InvalidDataException or JsonException or TaskCanceledException))
        {
            logger.LogError(ex, "Creating a calendar meeting failed");
            return Results.Problem("Vytvoreni schuzky nelze potvrdit; pozvanka mohla byt odeslana. Pred opakovanim overte kalendar agenta.", statusCode: 502);
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

            Admin ({options.AdminEmail}) schvali zpravou "@Pizza Koordinator schvaluji {change.Id}" nebo zamitne "@Pizza Koordinator zamitam {change.Id}".
            """;
        await PostAsync(text, ct);
        if (state.Channel is { } channel)
            await graph.SendMailAsync(channel, options.AdminEmail, $"Pizza Koordinator: schvaleni zmeny preferenci {courier.Name} ({change.Id})", text, ct);
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

    private bool TryParseLocal(string? value, out DateTimeOffset result)
    {
        result = default;
        if (string.IsNullOrWhiteSpace(value) || !DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)) return false;
        // Without an explicit offset the agent means coordinator-local time.
        if (HasOffset(value))
            return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out result);
        var local = DateTime.SpecifyKind(parsed, DateTimeKind.Unspecified);
        if (_zone.IsInvalidTime(local) || _zone.IsAmbiguousTime(local)) return false;
        result = new DateTimeOffset(local, _zone.GetUtcOffset(local));
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
