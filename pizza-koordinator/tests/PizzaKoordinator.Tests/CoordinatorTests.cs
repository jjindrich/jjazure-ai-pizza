using System.Security.Claims;
using Microsoft.Extensions.Logging.Abstractions;
using PizzaKoordinator.Api;

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
        static object Activity(string channelId, string conversationType, string id) => new
        {
            channelId,
            conversation = new { conversationType, id },
            recipient = new { agenticAppId = "agent-app", agenticUserId = "agent-user", tenantId = "tenant" },
            channelData = new { tenant = new { id = "tenant" } },
            serviceUrl = "https://example.test/"
        };

        coordinator.Capture(Activity("email", "personal", "mail"));
        Assert.Null(state.Channel);
        coordinator.Capture(Activity("msteams", "personal", "chat"));
        Assert.Equal("chat", state.Channel?.ConversationId);
        coordinator.Capture(Activity("msteams", "personal", "other-chat"));
        Assert.Equal("chat", state.Channel?.ConversationId);
        coordinator.Capture(Activity("msteams", "channel", "channel"));
        Assert.Equal("channel", state.Channel?.ConversationId);
        coordinator.Capture(Activity("email", "channel", "mail-channel"));
        Assert.Equal("channel", state.Channel?.ConversationId);
    }
}

public sealed class OptionsAndDiffTests
{
    [Theory]
    [InlineData("tid", "azp")]
    [InlineData("http://schemas.microsoft.com/identity/claims/tenantid", "appid")]
    public void Tool_caller_accepts_raw_or_mapped_tenant_and_rejects_other_callers(string tenantClaim, string clientClaim)
    {
        var options = new KoordinatorOptions { AllowedTenantId = "tenant", ToolClientId = "foundry" };
        ClaimsPrincipal Caller(string tenant, string client) =>
            new(new ClaimsIdentity([new(tenantClaim, tenant), new(clientClaim, client)], "Tools"));
        Assert.True(options.IsToolCaller(Caller("tenant", "foundry")));
        Assert.False(options.IsToolCaller(Caller("other", "foundry")));
        Assert.False(options.IsToolCaller(Caller("tenant", "other")));
        Assert.False(new KoordinatorOptions().IsToolCaller(new()));
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
