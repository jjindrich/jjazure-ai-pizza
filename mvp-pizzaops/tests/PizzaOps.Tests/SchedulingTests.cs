using PizzaOps.Api.Services;

namespace PizzaOps.Tests;

public sealed class SchedulingTests
{
    [Theory]
    [InlineData(-1, true)]
    [InlineData(0, true)]
    [InlineData(1, false)]
    public void ClassifiesPastDueScheduling(int seconds, bool expected)
    {
        var scheduler = new InMemoryWakeupScheduler(new PizzaOps.Api.Storage.InMemoryTaskStore());
        var now = DateTimeOffset.Parse("2026-01-01T12:00:00Z");
        Assert.Equal(expected, scheduler.IsPastDue(now.AddSeconds(seconds), now));
    }
}
