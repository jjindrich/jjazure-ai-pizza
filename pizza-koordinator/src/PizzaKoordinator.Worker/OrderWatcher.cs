namespace PizzaKoordinator.Worker;

/// <summary>Polls the Orders API for new orders and urges couriers who stay silent.</summary>
public sealed class OrderWatcher(
    KoordinatorOptions options,
    CoordinatorState state,
    OrdersClient orders,
    Coordinator coordinator,
    ILogger<OrderWatcher> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(Math.Max(5, options.PollSeconds)));
        do
        {
            try { await TickAsync(stoppingToken); }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested) { logger.LogError(ex, "Order watcher tick failed"); }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    internal async Task TickAsync(CancellationToken ct)
    {
        if (state.Channel is null) return;

        var newOrders = await orders.GetNewAsync(ct);
        state.RetainPendingAnnouncements(newOrders.Select(order => order.Id).ToHashSet());
        foreach (var order in newOrders)
        {
            if (!state.TryTrack(order.Id)) continue;
            try
            {
                await coordinator.AnnounceAsync(order, ct);
                state.AnnouncementSent(order.Id);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (state.DelayAnnouncement(order.Id) is { } delay)
                    logger.LogError(ex, "Announcing order {OrderId} failed; retrying after {Delay}", order.Id, delay);
                else
                    logger.LogError(ex, "Announcing order {OrderId} failed after it was assigned; no retry scheduled", order.Id);
            }
        }

        foreach (var tracked in state.TakeDueForUrge(TimeSpan.FromMinutes(options.UrgeAfterMinutes), options.MaxUrges))
        {
            try { await coordinator.UrgeAsync(tracked, ct); }
            catch (Exception ex) { logger.LogError(ex, "Urging couriers for order {OrderId} failed", tracked.OrderId); }
        }
    }
}
