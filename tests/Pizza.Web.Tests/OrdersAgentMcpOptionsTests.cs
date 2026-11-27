using System.Security.Claims;
using Pizza.Orders.Services;

namespace Pizza.Orders.Tests;

public sealed class OrdersAgentMcpOptionsTests
{
    [Fact]
    public void Allows_OnlyConfiguredTenantAndAgentClient()
    {
        var options = new OrdersAgentMcpOptions
        {
            TenantId = "tenant-1",
            Audience = "api://orders-api",
            AllowedClientId = "agent-client"
        };
        var principal = Principal(("tid", "TENANT-1"), ("azp", "agent-client"));

        Assert.True(options.Allows(principal));
        Assert.False(options.Allows(Principal(("tid", "other-tenant"), ("azp", "agent-client"))));
        Assert.False(options.Allows(Principal(("tid", "tenant-1"), ("azp", "bridge-client"))));
        Assert.False(options.Allows(Principal(("tid", "tenant-1"), ("appid", "bridge-client"))));
    }

    [Fact]
    public void Allows_AcceptsAppIdClaimWhenAzpIsAbsent()
    {
        var options = new OrdersAgentMcpOptions
        {
            TenantId = "tenant-1",
            Audience = "orders-api",
            AllowedClientId = "agent-client"
        };

        Assert.True(options.Allows(Principal(("tid", "tenant-1"), ("appid", "agent-client"))));
    }

    [Fact]
    public void IsConfigured_RequiresAllIdentityBindings()
    {
        var options = new OrdersAgentMcpOptions
        {
            TenantId = "tenant-1",
            Audience = "orders-api"
        };

        Assert.False(options.IsConfigured);
        Assert.False(options.Allows(Principal(("tid", "tenant-1"), ("azp", "agent-client"))));
    }

    [Theory]
    [InlineData("api://orders-api", "orders-api")]
    [InlineData("orders-api", "orders-api")]
    public void ValidAudiences_IncludesConfiguredAudienceForms(string audience, string expectedSecond)
    {
        var options = new OrdersAgentMcpOptions
        {
            TenantId = "tenant-1",
            Audience = audience,
            AllowedClientId = "agent-client"
        };

        var expected = audience.Equals(expectedSecond, StringComparison.OrdinalIgnoreCase)
            ? new[] { audience }
            : new[] { audience, expectedSecond };
        Assert.Equal(expected, options.ValidAudiences());
    }

    private static ClaimsPrincipal Principal(params (string Type, string Value)[] claims) =>
        new(new ClaimsIdentity(claims.Select(claim => new Claim(claim.Type, claim.Value)), "test"));
}
