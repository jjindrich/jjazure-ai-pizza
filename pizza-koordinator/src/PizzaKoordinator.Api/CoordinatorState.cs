namespace PizzaKoordinator.Api;

public sealed record ChannelIdentity(string TenantId, string ConversationId, string ServiceUrl, string AgenticIdentity);

public sealed class TrackedOrder
{
    public Guid OrderId { get; init; }
    public DateTimeOffset LastActivityAt { get; set; }
    public int Urges { get; set; }
    public string? Courier { get; set; }
    public string? EventId { get; set; }
}

public sealed record PreferenceChange(string Id, string Courier, string Summary, string NewSkill, string Diff);

// Single-replica in-memory state; see README limitations.
public sealed class CoordinatorState(TimeProvider time)
{
    private readonly Lock _gate = new();
    private readonly Dictionary<Guid, TrackedOrder> _orders = [];
    private readonly Dictionary<string, PreferenceChange> _changes = new(StringComparer.OrdinalIgnoreCase);

    public ChannelIdentity? Channel { get; set; }
    public string? ConversationId { get; set; }

    public bool TryTrack(Guid orderId)
    {
        lock (_gate)
            return _orders.TryAdd(orderId, new TrackedOrder { OrderId = orderId, LastActivityAt = time.GetUtcNow() });
    }

    public void Forget(Guid orderId)
    {
        lock (_gate) _orders.Remove(orderId);
    }

    public IReadOnlyList<TrackedOrder> Snapshot()
    {
        lock (_gate) return [.. _orders.Values];
    }

    public void CourierActivity()
    {
        lock (_gate)
            foreach (var order in _orders.Values.Where(o => o.Courier is null))
                order.LastActivityAt = time.GetUtcNow();
    }

    public IReadOnlyList<TrackedOrder> TakeDueForUrge(TimeSpan quietPeriod, int maxUrges)
    {
        var now = time.GetUtcNow();
        lock (_gate)
        {
            var due = _orders.Values
                .Where(o => o.Courier is null && o.Urges < maxUrges && now - o.LastActivityAt >= quietPeriod)
                .ToArray();
            foreach (var order in due)
            {
                order.Urges++;
                order.LastActivityAt = now;
            }
            return due;
        }
    }

    /// <summary>Returns the courier already holding the order, or null when <paramref name="courier"/> got it.</summary>
    public string? TryAssign(Guid orderId, string courier)
    {
        lock (_gate)
        {
            if (!_orders.TryGetValue(orderId, out var order))
                _orders[orderId] = order = new TrackedOrder { OrderId = orderId, LastActivityAt = time.GetUtcNow() };
            if (order.Courier is not null)
                return order.Courier;
            order.Courier = courier;
            return null;
        }
    }

    public TrackedOrder? Get(Guid orderId)
    {
        lock (_gate) return _orders.GetValueOrDefault(orderId);
    }

    public void Unassign(Guid orderId)
    {
        lock (_gate)
            if (_orders.TryGetValue(orderId, out var order)) order.Courier = null;
    }

    public PreferenceChange AddChange(string courier, string summary, string newSkill, string diff)
    {
        var change = new PreferenceChange(Guid.NewGuid().ToString("N")[..6], courier, summary, newSkill, diff);
        lock (_gate) _changes[change.Id] = change;
        return change;
    }

    public bool TryTakeChange(string id, out PreferenceChange change)
    {
        lock (_gate) return _changes.Remove(id, out change!);
    }

    public void RestoreChange(PreferenceChange change)
    {
        lock (_gate) _changes[change.Id] = change;
    }
}
