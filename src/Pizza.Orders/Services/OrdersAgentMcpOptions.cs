using System.Security.Claims;

namespace Pizza.Orders.Services;

public sealed class OrdersAgentMcpOptions
{
    public const string SectionName = "Pizza:AgentMcp";

    public string? TenantId { get; set; }
    public string? Audience { get; set; }
    public string? AllowedClientId { get; set; }

    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(TenantId) &&
        !string.IsNullOrWhiteSpace(Audience) &&
        !string.IsNullOrWhiteSpace(AllowedClientId);

    public bool Allows(ClaimsPrincipal principal)
    {
        var tenantId = principal.FindFirst("tid")?.Value;
        var clientId = (principal.FindFirst("azp") ?? principal.FindFirst("appid"))?.Value;

        return IsConfigured &&
            string.Equals(TenantId, tenantId, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(AllowedClientId, clientId, StringComparison.OrdinalIgnoreCase);
    }

    public string[] ValidAudiences()
    {
        if (string.IsNullOrWhiteSpace(Audience))
            return [];

        var clientIdAudience = Audience.StartsWith("api://", StringComparison.OrdinalIgnoreCase)
            ? Audience["api://".Length..]
            : Audience;
        return string.Equals(Audience, clientIdAudience, StringComparison.OrdinalIgnoreCase)
            ? [Audience]
            : [Audience, clientIdAudience];
    }
}
