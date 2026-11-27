using System.Security.Claims;

namespace PizzaKoordinator.Gateway;

public sealed class GatewayOptions
{
    public const string SectionName = "Gateway";
    public string? WorkerUrl { get; set; }
    public string? AllowedTenantId { get; set; }
    public string? ToolAudience { get; set; }
    public string? FoundryClientId { get; set; }
    public bool AllowLocalAuthBypass { get; set; }

    /// <summary>Only the Foundry project identity from the allowed tenant may call the agent tools.</summary>
    public bool IsFoundryCaller(ClaimsPrincipal user) =>
        !string.IsNullOrWhiteSpace(AllowedTenantId) && !string.IsNullOrWhiteSpace(FoundryClientId) &&
        (user.FindFirst("tid") ?? user.FindFirst("http://schemas.microsoft.com/identity/claims/tenantid"))?.Value == AllowedTenantId &&
        (user.FindFirst("azp") ?? user.FindFirst("appid"))?.Value == FoundryClientId;
}
