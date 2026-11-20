using System.Security.Claims;

namespace PizzaOps.Api.Security;

public interface IToolAuthorization
{
    bool IsAuthorized(ClaimsPrincipal principal);
}

public sealed class ToolAuthorizationPolicy(
    ApiOptions api,
    PizzaOpsOptions options,
    IHostEnvironment environment,
    ILogger<ToolAuthorizationPolicy> logger) : IToolAuthorization
{
    public bool IsAuthorized(ClaimsPrincipal principal)
    {
        if (environment.IsDevelopment() && options.AllowLocalAuthBypass)
            return true;

        if (!(principal.Identity?.IsAuthenticated ?? false))
            return false;

        var audience = principal.FindFirst("aud")?.Value ?? principal.FindFirst("http://schemas.microsoft.com/identity/claims/audience")?.Value;
        var issuer = principal.FindFirst("iss")?.Value;
        var tenant = principal.FindFirst("tid")?.Value
            ?? principal.FindFirst("http://schemas.microsoft.com/identity/claims/tenantid")?.Value;
        var clientId = principal.FindFirst("azp")?.Value ?? principal.FindFirst("appid")?.Value;
        var roles = principal.FindAll("roles").Select(claim => claim.Value);
        var roleAllowed = !string.IsNullOrWhiteSpace(options.RequiredToolRole)
            && roles.Contains(options.RequiredToolRole, StringComparer.Ordinal);

        var authorized = Exact(audience, api.Audience)
            && OneOf(issuer, options.AllowedIssuers)
            && Exact(tenant, options.AllowedTenantId)
            && (Exact(clientId, api.AllowedClientId) || roleAllowed);
        if (!authorized)
        {
            logger.LogWarning(
                "PizzaOps tool authorization denied. Audience={Audience}, issuer={Issuer}, tenant={Tenant}, clientId={ClientId}, roles={Roles}",
                audience,
                issuer,
                tenant,
                clientId,
                string.Join(',', roles));
        }
        return authorized;
    }

    private static bool Exact(string? actual, string? expected) =>
        !string.IsNullOrWhiteSpace(expected) &&
        string.Equals(actual, expected, StringComparison.Ordinal);

    private static bool OneOf(string? actual, string? expected)
    {
        if (string.IsNullOrWhiteSpace(actual) || string.IsNullOrWhiteSpace(expected))
            return false;
        return expected.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Contains(actual, StringComparer.Ordinal);
    }
}

public static class ToolAuthorizationExtensions
{
    public static void RequireToolAuthorization(this RouteGroupBuilder group) =>
        group.WithMetadata(new RequireToolAuthorizationAttribute());

    public static void RequireToolAuthorization(this RouteHandlerBuilder endpoint) =>
        endpoint.WithMetadata(new RequireToolAuthorizationAttribute());
}

[AttributeUsage(AttributeTargets.Method | AttributeTargets.Class)]
public sealed class RequireToolAuthorizationAttribute : Attribute;
