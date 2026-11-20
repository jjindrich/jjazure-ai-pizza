using PizzaOps.Api;
using PizzaOps.Api.Storage;

namespace PizzaOps.Tests;

public sealed class TaskStoreTests
{
    [Fact]
    public async Task EnforcesOptimisticConcurrency()
    {
        var store = new InMemoryTaskStore();
        var created = await store.CreateAsync(new DurableTask { TenantId = "tenant" }, default);
        var stale = await store.GetAsync("tenant", created.Id, default);
        var fresh = await store.GetAsync("tenant", created.Id, default);
        fresh!.Status = "first";
        await store.UpdateAsync(fresh, fresh.ETag!, default);

        stale!.Status = "stale";
        await Assert.ThrowsAsync<ConcurrencyException>(() =>
            store.UpdateAsync(stale, stale.ETag!, default));
    }

    [Fact]
    public async Task IdempotencyAndTriggerClaimsAreSingleWinner()
    {
        var store = new InMemoryTaskStore();
        var attempts = await Task.WhenAll(Enumerable.Range(0, 10).Select(_ =>
            store.TryCreateIdempotencyAsync("tenant", "same-key", "test", default)));
        Assert.Single(attempts, result => result);

        var claims = await Task.WhenAll(Enumerable.Range(0, 10).Select(_ =>
            store.TryClaimTriggerAsync("tenant", "trigger", default)));
        Assert.Single(claims, result => result);
    }
}
