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
}

public sealed class OptionsAndDiffTests
{
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
