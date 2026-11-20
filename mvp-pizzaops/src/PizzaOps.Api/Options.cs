namespace PizzaOps.Api;

public sealed class PizzaOpsOptions
{
    public const string SectionName = "PizzaOps";
    public string Environment { get; set; } = "Development";
    public string? FoundryEndpoint { get; set; }
    public string? FoundryAgentName { get; set; }
    public string? CosmosEndpoint { get; set; }
    public string? CosmosDatabase { get; set; }
    public string CosmosTasksContainer { get; set; } = "tasks";
    public string CosmosEventsContainer { get; set; } = "events";
    public string? ServiceBusNamespace { get; set; }
    public string? ServiceBusQueue { get; set; }
    public string? GraphWebhookClientState { get; set; }
    public bool AllowLocalFallbacks { get; set; }
    public string? AllowedIssuers { get; set; }
    public string? AllowedTenantId { get; set; }
    public string? RequiredToolRole { get; set; }
    public bool AllowLocalAuthBypass { get; set; }
}

public sealed class ApiOptions
{
    public const string SectionName = "Api";
    public string? Audience { get; set; }
    public string? AllowedClientId { get; set; }
}
