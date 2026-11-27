using System.Security.Claims;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging.Abstractions;
using Pizza.Contracts;
using PizzaKoordinator.Gateway;
using PizzaKoordinator.Worker;

namespace PizzaKoordinator.Tests;

public sealed class CoordinatorStateTests
{
    private sealed class ManualTime : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = new(2025, 1, 31, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public void Urges_only_after_quiet_period_and_courier_activity_resets_it()
    {
        var time = new ManualTime();
        var state = new CoordinatorState(time);
        var order = Guid.NewGuid();
        state.TryTrack(order);

        time.Now += TimeSpan.FromMinutes(2);
        Assert.Empty(state.TakeDueForUrge(TimeSpan.FromMinutes(3), 5));

        state.CourierActivity();
        time.Now += TimeSpan.FromMinutes(2);
        Assert.Empty(state.TakeDueForUrge(TimeSpan.FromMinutes(3), 5));

        time.Now += TimeSpan.FromMinutes(1);
        Assert.Equal(1, Assert.Single(state.TakeDueForUrge(TimeSpan.FromMinutes(3), 5)).Urges);
        Assert.Empty(state.TakeDueForUrge(TimeSpan.FromMinutes(3), 5));
    }

    [Fact]
    public void Assigned_or_exhausted_orders_are_not_urged()
    {
        var time = new ManualTime();
        var state = new CoordinatorState(time);
        var assigned = Guid.NewGuid();
        var exhausted = Guid.NewGuid();
        state.TryTrack(assigned);
        state.TryTrack(exhausted);
        state.TryAssign(assigned, "Kuryr1");

        time.Now += TimeSpan.FromMinutes(3);
        Assert.Equal(exhausted, Assert.Single(state.TakeDueForUrge(TimeSpan.FromMinutes(3), 1)).OrderId);
        time.Now += TimeSpan.FromMinutes(3);
        Assert.Empty(state.TakeDueForUrge(TimeSpan.FromMinutes(3), 1));
    }

    [Fact]
    public void First_courier_wins_the_order()
    {
        var state = new CoordinatorState(new ManualTime());
        var order = Guid.NewGuid();
        state.TryTrack(order);

        Assert.Null(state.TryAssign(order, "Kuryr2"));
        Assert.Equal("Kuryr2", state.TryAssign(order, "Kuryr3"));
        state.Unassign(order);
        Assert.Null(state.TryAssign(order, "Kuryr3"));
    }

    [Fact]
    public void Preference_change_can_be_taken_once_and_restored()
    {
        var state = new CoordinatorState(new ManualTime());
        var change = state.AddChange("Kuryr1", "jen odpoledne", "skill", "+ x");

        Assert.True(state.TryTakeChange(change.Id.ToUpperInvariant(), out _));
        Assert.False(state.TryTakeChange(change.Id, out _));
        state.RestoreChange(change);
        Assert.True(state.TryTakeChange(change.Id, out var restored));
        Assert.Equal("skill", restored.NewSkill);
    }

    [Fact]
    public void Failed_announcement_retries_with_backoff_without_hiding_other_orders()
    {
        var time = new ManualTime();
        var state = new CoordinatorState(time);
        var order = Guid.NewGuid();

        Assert.True(state.TryTrack(order));
        Assert.Equal(TimeSpan.FromSeconds(30), state.DelayAnnouncement(order));
        Assert.Empty(state.Snapshot());
        Assert.False(state.TryTrack(order));
        Assert.True(state.TryTrack(Guid.NewGuid()));

        time.Now += TimeSpan.FromSeconds(30);
        Assert.True(state.TryTrack(order));
        Assert.Equal(TimeSpan.FromMinutes(1), state.DelayAnnouncement(order));
        time.Now += TimeSpan.FromSeconds(59);
        Assert.False(state.TryTrack(order));
        time.Now += TimeSpan.FromSeconds(1);
        Assert.True(state.TryTrack(order));
        state.AnnouncementSent(order);
        state.Forget(order);
        Assert.True(state.TryTrack(order));
        Assert.Equal(TimeSpan.FromSeconds(30), state.DelayAnnouncement(order));
    }

    [Fact]
    public void Failed_announcement_does_not_forget_a_concurrent_assignment()
    {
        var state = new CoordinatorState(new ManualTime());
        var order = Guid.NewGuid();
        Assert.True(state.TryTrack(order));
        Assert.Null(state.TryAssign(order, "Kuryr1"));

        Assert.Null(state.DelayAnnouncement(order));
        Assert.Equal("Kuryr1", state.Get(order)?.Courier);
    }

    [Fact]
    public void Announcement_retry_is_capped_and_cleared_for_orders_no_longer_new()
    {
        var time = new ManualTime();
        var state = new CoordinatorState(time);
        var order = Guid.NewGuid();
        foreach (var seconds in new[] { 30, 60, 120, 240, 480, 900, 900 })
        {
            Assert.True(state.TryTrack(order));
            Assert.Equal(TimeSpan.FromSeconds(seconds), state.DelayAnnouncement(order));
            time.Now += TimeSpan.FromSeconds(seconds);
        }

        state.RetainPendingAnnouncements(new HashSet<Guid>());
        Assert.True(state.TryTrack(order));
        Assert.Equal(TimeSpan.FromSeconds(30), state.DelayAnnouncement(order));
    }
}

public sealed class ChannelCaptureTests
{
    [Fact]
    public void Only_teams_activities_bind_and_a_channel_supersedes_a_personal_chat()
    {
        var time = TimeProvider.System;
        var state = new CoordinatorState(time);
        var coordinator = new Coordinator(new KoordinatorOptions(), state, null!, null!, null!, null!, null!, time,
            NullLogger<Coordinator>.Instance);
        static JsonElement Activity(string channelId, string conversationType, string id) => JsonSerializer.SerializeToElement(new
        {
            type = "message",
            text = "ahoj",
            channelId,
            conversation = new { conversationType, id },
            from = new { id = "user", name = "Kuryr1", aadObjectId = "courier-1" },
            recipient = new { agenticAppId = "agent-app", agenticUserId = "agent-user", tenantId = "tenant" },
            channelData = new { tenant = new { id = "tenant" } },
            serviceUrl = "https://example.test/"
        });

        coordinator.Capture(Activity("email", "personal", "mail"));
        Assert.Null(state.Channel);
        coordinator.Capture(Activity("msteams", "personal", "chat"));
        Assert.Equal("chat", state.Channel?.ConversationId);
        coordinator.Capture(Activity("msteams", "personal", "other-chat"));
        Assert.Equal("chat", state.Channel?.ConversationId);
        var inbound = coordinator.Capture(Activity("msteams", "channel", "channel;messageid=42"));
        Assert.Equal("channel;messageid=42", state.Channel?.ConversationId);
        Assert.Equal("channel;messageid=42", inbound.Reply.ConversationId);
        Assert.Equal(("courier-1", "Kuryr1", "message", "ahoj"), (inbound.Sender.AadObjectId, inbound.Sender.Name, inbound.Type, inbound.Text));
        Assert.Contains("agent-user", inbound.Reply.AgenticIdentity);
        coordinator.Capture(Activity("email", "channel", "mail-channel"));
        Assert.Equal("channel;messageid=42", state.Channel?.ConversationId);
    }
}

public sealed class MeetingSchedulingTests
{
    private sealed class FakeGraph : IGraphClient
    {
        public ChannelIdentity? Identity { get; private set; }
        public JsonObject? Event { get; private set; }
        public int EventCalls { get; private set; }
        public Exception? EventError { get; init; }
        public Exception? MailError { get; init; }

        public Task<CreatedEvent> CreateEventAsync(ChannelIdentity identity, object graphEvent, CancellationToken ct)
        {
            Identity = identity;
            Event = JsonSerializer.SerializeToNode(graphEvent)!.AsObject();
            EventCalls++;
            return EventError is null ? Task.FromResult(new CreatedEvent("event-1", null)) : Task.FromException<CreatedEvent>(EventError);
        }

        public Task SendMailAsync(ChannelIdentity identity, string to, string subject, string body, CancellationToken ct) =>
            MailError is null ? Task.CompletedTask : Task.FromException(MailError);

        public Task ReactAsync(ChannelIdentity identity, string messagePath, string reaction, CancellationToken ct) => Task.CompletedTask;
    }

    private static Coordinator Create(CoordinatorState state, IGraphClient graph, KoordinatorOptions? options = null, OrdersClient? orders = null) =>
        new(options ?? new KoordinatorOptions(), state, null!, null!, graph, orders!, null!, TimeProvider.System, NullLogger<Coordinator>.Instance);

    private static JsonNode ResultValue(IResult result) =>
        JsonSerializer.SerializeToNode(Assert.IsAssignableFrom<IValueHttpResult>(result).Value)!;

    [Fact]
    public async Task Meeting_uses_agent_identity_utc_and_a_stable_transaction_id()
    {
        var channel = new ChannelIdentity("tenant", "chat", "https://example.test", "agent-user");
        var state = new CoordinatorState(TimeProvider.System) { Channel = channel };
        var graph = new FakeGraph();
        var coordinator = Create(state, graph);
        var request = new ScheduleMeetingRequest("Pizza", "2026-12-01T08:00", 30,
            ["admin@example.test", "user@example.test", "ADMIN@example.test"], "Praha");

        var result = ResultValue(await coordinator.ScheduleMeetingAsync(request, default));
        Assert.True(result["created"]!.GetValue<bool>());
        Assert.True(result["invitationsSubmitted"]!.GetValue<bool>());
        Assert.False(result["deliveryVerified"]!.GetValue<bool>());
        Assert.Equal(channel, graph.Identity);
        Assert.Equal("2026-12-01T07:00:00", graph.Event!["start"]!["dateTime"]!.ToString());
        Assert.Equal("2026-12-01T07:30:00", graph.Event["end"]!["dateTime"]!.ToString());
        Assert.Equal("UTC", graph.Event["start"]!["timeZone"]!.ToString());
        Assert.Equal("Praha", graph.Event["location"]!["displayName"]!.ToString());
        Assert.Equal(2, graph.Event["attendees"]!.AsArray().Count);
        var transactionId = graph.Event["transactionId"]!.ToString();
        Assert.True(Guid.TryParse(transactionId, out _));

        await coordinator.ScheduleMeetingAsync(request with { Attendees = ["USER@example.test", "admin@example.test"] }, default);
        Assert.Equal(transactionId, graph.Event!["transactionId"]!.ToString());
        await coordinator.ScheduleMeetingAsync(request with { Start = "2026-12-01T09:00" }, default);
        Assert.NotEqual(transactionId, graph.Event!["transactionId"]!.ToString());
    }

    [Theory]
    [InlineData("2026-03-29T02:30")]
    [InlineData("2026-10-25T02:30")]
    [InlineData("2026-12-01")]
    public async Task Invalid_or_ambiguous_local_time_does_not_create_an_event(string start)
    {
        var graph = new FakeGraph();
        var coordinator = Create(new CoordinatorState(TimeProvider.System) { Channel = new("tenant", "chat", "https://example.test", "agent") }, graph);
        var result = await coordinator.ScheduleMeetingAsync(new("Pizza", start, 30, ["admin@example.test"]), default);
        Assert.Equal(400, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        Assert.Equal(0, graph.EventCalls);
    }

    [Fact]
    public async Task Invalid_attendees_and_missing_agent_identity_do_not_create_an_event()
    {
        var state = new CoordinatorState(TimeProvider.System) { Channel = new("tenant", "chat", "https://example.test", "agent") };
        var graph = new FakeGraph();
        var coordinator = Create(state, graph);
        var request = new ScheduleMeetingRequest("Pizza", "2026-10-25T02:30+01:00", 30, ["not-an-email"]);
        Assert.Equal(400, Assert.IsAssignableFrom<IStatusCodeHttpResult>(await coordinator.ScheduleMeetingAsync(request, default)).StatusCode);
        state.Channel = null;
        Assert.Equal(409, Assert.IsAssignableFrom<IStatusCodeHttpResult>(
            await coordinator.ScheduleMeetingAsync(request with { Attendees = ["admin@example.test"] }, default)).StatusCode);
        Assert.Equal(0, graph.EventCalls);
    }

    [Fact]
    public async Task An_uncertain_graph_response_is_not_reported_as_success()
    {
        var state = new CoordinatorState(TimeProvider.System) { Channel = new("tenant", "chat", "https://example.test", "agent") };
        var graph = new FakeGraph { EventError = new HttpRequestException("Connection lost") };
        var result = await Create(state, graph).ScheduleMeetingAsync(new("Pizza", "2026-12-01T08:00", 30, ["admin@example.test"]), default);
        Assert.Equal(502, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
    }

    [Fact]
    public async Task Missing_online_link_is_reported_as_a_partial_result()
    {
        var state = new CoordinatorState(TimeProvider.System) { Channel = new("tenant", "chat", "https://example.test", "agent") };
        var graph = new FakeGraph();
        var result = ResultValue(await Create(state, graph).ScheduleMeetingAsync(
            new("Pizza", "2026-10-25T02:30+01:00", 30, ["admin@example.test"], IsOnline: true), default));
        Assert.True(result["created"]!.GetValue<bool>());
        Assert.NotNull(result["warning"]);
        Assert.Equal("teamsForBusiness", graph.Event!["onlineMeetingProvider"]!.ToString());
        Assert.Equal("2026-10-25T01:30:00", graph.Event["start"]!["dateTime"]!.ToString());
    }

    [Fact]
    public async Task Calendar_creation_requires_a_201_response_and_event_id()
    {
        using var created = new HttpResponseMessage(HttpStatusCode.Created)
        {
            Content = JsonContent.Create(new { id = "event-1", onlineMeeting = new { joinUrl = "https://teams.example.test/join" } })
        };
        Assert.Equal(new CreatedEvent("event-1", "https://teams.example.test/join"), await GraphClient.ReadCreatedEventAsync(created, default));
        using var missingId = new HttpResponseMessage(HttpStatusCode.Created) { Content = JsonContent.Create(new { subject = "Pizza" }) };
        await Assert.ThrowsAsync<InvalidDataException>(() => GraphClient.ReadCreatedEventAsync(missingId, default));
        using var unexpectedStatus = new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new { id = "event-1" }) };
        await Assert.ThrowsAsync<InvalidDataException>(() => GraphClient.ReadCreatedEventAsync(unexpectedStatus, default));
    }

    private sealed class OrderHandler(PizzaOrder order) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(order, options: OrdersClient.Json) });
    }

    [Fact]
    public async Task Failed_admin_mail_does_not_repeat_an_already_created_delivery_invitation()
    {
        var order = new PizzaOrder(Guid.NewGuid(), new Customer("Test", "Praha"), [], OrderStatus.New, DateTimeOffset.UtcNow);
        var orders = new OrdersClient(new HttpClient(new OrderHandler(order)) { BaseAddress = new Uri("https://orders.example.test/") });
        var state = new CoordinatorState(TimeProvider.System) { Channel = new("tenant", "chat", "https://example.test", "agent") };
        var graph = new FakeGraph { MailError = new HttpRequestException("Mail failed") };
        var options = new KoordinatorOptions { Couriers = [new Courier { Name = "Kuryr1", Email = "courier@example.test" }] };
        var coordinator = Create(state, graph, options, orders);
        var request = new AssignRequest(order.Id, "Kuryr1", "2026-12-01T08:00");

        Assert.Equal(502, Assert.IsAssignableFrom<IStatusCodeHttpResult>(await coordinator.AssignAsync(request, default)).StatusCode);
        Assert.Equal("event-1", state.Get(order.Id)!.EventId);
        var repeat = ResultValue(await coordinator.AssignAsync(request, default));
        Assert.True(repeat["invitationSent"]!.GetValue<bool>());
        Assert.False(repeat["adminNotified"]!.GetValue<bool>());
        Assert.Equal(1, graph.EventCalls);
    }
}

public sealed class OptionsAndDiffTests
{
    [Theory]
    [InlineData("tid", "azp")]
    [InlineData("http://schemas.microsoft.com/identity/claims/tenantid", "appid")]
    public void Each_hop_accepts_only_its_caller_identity_from_the_allowed_tenant(string tenantClaim, string clientClaim)
    {
        var options = new KoordinatorOptions { AllowedTenantId = "tenant", GatewayClientId = "gateway" };
        ClaimsPrincipal Caller(string tenant, string client) =>
            new(new ClaimsIdentity([new(tenantClaim, tenant), new(clientClaim, client)], "Tools"));
        Assert.True(options.IsGatewayCaller(Caller("tenant", "gateway")));
        Assert.False(options.IsGatewayCaller(Caller("other", "gateway")));
        Assert.False(options.IsGatewayCaller(Caller("tenant", "foundry")));
        Assert.False(new KoordinatorOptions().IsGatewayCaller(new()));

        var gateway = new GatewayOptions { AllowedTenantId = "tenant", FoundryClientId = "foundry" };
        Assert.True(gateway.IsFoundryCaller(Caller("tenant", "foundry")));
        Assert.False(gateway.IsFoundryCaller(Caller("other", "foundry")));
        Assert.False(gateway.IsFoundryCaller(Caller("tenant", "gateway")));
        Assert.False(new GatewayOptions().IsFoundryCaller(new()));
    }

    [Fact]
    public void Only_configured_admin_is_admin()
    {
        var options = new KoordinatorOptions { AdminAadObjectId = "ADMIN-ID" };
        Assert.True(options.IsAdmin("admin-id"));
        Assert.False(options.IsAdmin("someone"));
        Assert.False(new KoordinatorOptions().IsAdmin(null));
    }

    [Fact]
    public void Sender_is_matched_by_object_id_then_name()
    {
        var options = new KoordinatorOptions { Couriers = [new() { Name = "Kuryr1", AadObjectId = "oid-1" }, new() { Name = "Kuryr2" }] };
        Assert.Equal("Kuryr1", options.FindSender("OID-1", "Somebody")?.Name);
        Assert.Equal("Kuryr2", options.FindSender(null, "kuryr2")?.Name);
        Assert.Null(options.FindSender("x", "Kuryr9"));
    }

    [Fact]
    public void Diff_shows_only_changed_lines()
    {
        var diff = TextDiff.Lines("a\r\nb\nc\n", "a\nB\nc\nd");
        Assert.Equal("+ B\n- b\n+ d", diff);
        Assert.Equal("", TextDiff.Lines("same\n", "same"));
    }
}

public sealed class TeamsReplyTests
{
#pragma warning disable OPENAI001
    [Fact]
    public void Only_last_assistant_message_is_returned()
    {
        var items = new[]
        {
            OpenAI.Responses.ResponseItem.CreateAssistantMessageItem("Volám nástroj list_new_orders…"),
            OpenAI.Responses.ResponseItem.CreateAssistantMessageItem("Máme 5 objednávek.")
        };
        Assert.Equal("Máme 5 objednávek.", FoundryAgent.FinalText(items));
        Assert.Null(FoundryAgent.FinalText([]));
    }
#pragma warning restore OPENAI001

    [Theory]
    [InlineData("""{"id":"m1","conversation":{"id":"19:a@unq.gbl.spaces","conversationType":"personal"}}""", "chats/19%3Aa%40unq.gbl.spaces/messages/m1")]
    [InlineData("""{"id":"r1","conversation":{"id":"19:c@thread.tacv2;messageid=r1","conversationType":"channel"},"channelData":{"team":{"aadGroupId":"g"},"channel":{"id":"19:c@thread.tacv2"}}}""", "teams/g/channels/19%3Ac%40thread.tacv2/messages/r1")]
    [InlineData("""{"id":"m2","conversation":{"id":"19:c@thread.tacv2;messageid=r1","conversationType":"channel"},"channelData":{"team":{"aadGroupId":"g"},"channel":{"id":"19:c@thread.tacv2"}}}""", "teams/g/channels/19%3Ac%40thread.tacv2/messages/r1/replies/m2")]
    [InlineData("""{"id":"m3","conversation":{"id":"19:c@thread.tacv2","conversationType":"channel"},"channelData":{}}""", null)]
    public void Seen_reaction_targets_the_inbound_message(string json, string? expected) =>
        Assert.Equal(expected, TeamsInbox.MessagePath(JsonDocument.Parse(json).RootElement));
}
