using PizzaOps.Api;
using PizzaOps.Api.Services;

namespace PizzaOps.Tests;

public sealed class DeliveryPlannerTests
{
    [Fact]
    public void CalculatesArrivalAndOrderDeadline()
    {
        var lunch = new DateTimeOffset(2026, 1, 2, 12, 30, 0, TimeSpan.FromHours(1));
        var result = new DeliveryPlanner().Calculate(new(lunch, "Europe/Prague", 40));

        Assert.Equal(lunch.AddMinutes(-5), result.TargetArrival);
        Assert.Equal(lunch.AddMinutes(-45), result.OrderDeadline);
        Assert.Equal(40, result.ExpectedDeliveryMinutes);
        Assert.Equal("Europe/Prague", result.TimeZone);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(241)]
    public void RejectsInvalidDeliveryDuration(int minutes)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new DeliveryPlanner().Calculate(new(DateTimeOffset.UtcNow, "Europe/Prague", minutes)));
    }

    [Fact]
    public void RejectsMissingTimeZone()
    {
        Assert.Throws<ArgumentException>(() =>
            new DeliveryPlanner().Calculate(new(DateTimeOffset.UtcNow, "", 40)));
    }
}
