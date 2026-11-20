using System.Security.Claims;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging.Abstractions;
using PizzaOps.Api;
using PizzaOps.Api.Security;

namespace PizzaOps.Tests;

public sealed class ToolAuthorizationTests
{
    private static readonly PizzaOpsOptions Options = new()
    {
        AllowedIssuers = "https://sts.windows.net/tenant/;https://login.microsoftonline.com/tenant/v2.0",
        AllowedTenantId = "tenant",
        RequiredToolRole = "PizzaOps.Tool"
    };
    private static readonly ApiOptions Api = new()
    {
        Audience = "PizzaOps",
        AllowedClientId = "foundry-project"
    };

    [Fact]
    public void DeniesAuthenticatedButUnlistedCaller()
    {
        var policy = new ToolAuthorizationPolicy(Api, Options, ProductionEnvironment.Instance, NullLogger<ToolAuthorizationPolicy>.Instance);
        Assert.False(policy.IsAuthorized(Principal("other-project")));
    }

    [Fact]
    public void AcceptsAllowedClientAndExactTenantIssuerAudience()
    {
        var policy = new ToolAuthorizationPolicy(Api, Options, ProductionEnvironment.Instance, NullLogger<ToolAuthorizationPolicy>.Instance);
        Assert.True(policy.IsAuthorized(Principal("foundry-project")));
    }

    [Fact]
    public void AcceptsAllowedRoleSeparatelyFromBusinessPolicy()
    {
        var principal = Principal("another-client",
            new Claim("roles", "PizzaOps.Tool"));
        Assert.True(new ToolAuthorizationPolicy(Api, Options, ProductionEnvironment.Instance, NullLogger<ToolAuthorizationPolicy>.Instance).IsAuthorized(principal));
    }

    [Fact]
    public void LocalBypassRequiresExplicitDevelopmentFlag()
    {
        var local = new PizzaOpsOptions();
        Assert.False(new ToolAuthorizationPolicy(Api, local, DevelopmentEnvironment.Instance, NullLogger<ToolAuthorizationPolicy>.Instance).IsAuthorized(new ClaimsPrincipal()));
        local.AllowLocalAuthBypass = true;
        Assert.True(new ToolAuthorizationPolicy(Api, local, DevelopmentEnvironment.Instance, NullLogger<ToolAuthorizationPolicy>.Instance).IsAuthorized(new ClaimsPrincipal()));
    }

    private static ClaimsPrincipal Principal(string clientId, params Claim[] extra)
    {
        var claims = new List<Claim>
        {
            new("aud", Api.Audience!),
            new("iss", "https://sts.windows.net/tenant/"),
            new("tid", Options.AllowedTenantId!),
            new("azp", clientId)
        };
        claims.AddRange(extra);
        return new ClaimsPrincipal(new ClaimsIdentity(claims, "test"));
    }

    private abstract class TestEnvironment : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = "";
        public string ApplicationName { get; set; } = "tests";
        public string ContentRootPath { get; set; } = ".";
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
    private sealed class ProductionEnvironment : TestEnvironment
    {
        public static readonly ProductionEnvironment Instance = new() { EnvironmentName = Environments.Production };
    }
    private sealed class DevelopmentEnvironment : TestEnvironment
    {
        public static readonly DevelopmentEnvironment Instance = new() { EnvironmentName = Environments.Development };
    }
}
