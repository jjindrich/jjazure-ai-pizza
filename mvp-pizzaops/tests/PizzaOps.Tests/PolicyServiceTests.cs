using PizzaOps.Api;
using PizzaOps.Api.Services;

namespace PizzaOps.Tests;

public sealed class PolicyServiceTests
{
    private readonly PolicyService _policy = new();

    [Theory]
    [InlineData("read")]
    [InlineData("availability")]
    [InlineData("plan.delivery")]
    [InlineData("notification")]
    public void PermitsAutonomousActions(string action)
    {
        Assert.Equal(PolicyEffect.Permit, _policy.Decide(new("task", action, false, false)).Effect);
    }

    [Fact]
    public void RequiresApprovalForMeetingAffectingOthers()
    {
        Assert.Equal(PolicyEffect.ApprovalRequired,
            _policy.Decide(new("task", "create-meeting", true, false)).Effect);
    }

    [Theory]
    [InlineData("payment")]
    [InlineData("purchase pizza")]
    [InlineData("credit card charge")]
    public void DeniesFinancialActions(string action)
    {
        Assert.Equal(PolicyEffect.Deny, _policy.Decide(new("task", action, false, false)).Effect);
    }
}
