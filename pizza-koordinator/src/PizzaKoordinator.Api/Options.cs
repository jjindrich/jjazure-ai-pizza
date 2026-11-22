using System.Security.Claims;

namespace PizzaKoordinator.Api;

public sealed class KoordinatorOptions
{
    public const string SectionName = "Koordinator";
    public string? FoundryEndpoint { get; set; }
    public string FoundryAgentName { get; set; } = "pizza-koordinator-agent";
    public string AgentFoundryFeatures { get; set; } = "MicrosoftCopilot=V1Preview";
    public string PreferencesSkillName { get; set; } = "courier-preferences";
    public string? OrdersApiUrl { get; set; }
    public string AdminEmail { get; set; } = "jjadmin@jjazdev.org";
    public string? AdminAadObjectId { get; set; }
    public string TimeZone { get; set; } = "Europe/Prague";
    public int PollSeconds { get; set; } = 30;
    public int UrgeAfterMinutes { get; set; } = 3;
    public int MaxUrges { get; set; } = 5;
    public string? AllowedTenantId { get; set; }
    public string? ToolAudience { get; set; }
    public string? ToolClientId { get; set; }
    public bool AllowLocalAuthBypass { get; set; }
    public List<Courier> Couriers { get; set; } = [];

    public Courier? FindCourier(string? name) =>
        Couriers.FirstOrDefault(c => string.Equals(c.Name, name?.Trim(), StringComparison.OrdinalIgnoreCase));

    public Courier? FindSender(string? aadObjectId, string? displayName) =>
        Couriers.FirstOrDefault(c => !string.IsNullOrEmpty(aadObjectId) &&
            string.Equals(c.AadObjectId, aadObjectId, StringComparison.OrdinalIgnoreCase))
        ?? FindCourier(displayName);

    public bool IsAdmin(string? aadObjectId) =>
        !string.IsNullOrWhiteSpace(AdminAadObjectId) &&
        string.Equals(AdminAadObjectId, aadObjectId, StringComparison.OrdinalIgnoreCase);

    public bool IsToolCaller(ClaimsPrincipal user) =>
        !string.IsNullOrWhiteSpace(AllowedTenantId) && !string.IsNullOrWhiteSpace(ToolClientId) &&
        (user.FindFirst("tid") ?? user.FindFirst("http://schemas.microsoft.com/identity/claims/tenantid"))?.Value == AllowedTenantId &&
        (user.FindFirst("azp") ?? user.FindFirst("appid"))?.Value == ToolClientId;
}

public sealed class Courier
{
    public string Name { get; set; } = "";
    public string Email { get; set; } = "";
    public string? AadObjectId { get; set; }
}
