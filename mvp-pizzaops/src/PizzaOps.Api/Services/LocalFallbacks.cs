namespace PizzaOps.Api.Services;

public sealed class LocalFoundryBridge : IFoundryBridge
{
    public Task<FoundryTurn> SendAsync(TenantIdentity identity, string? conversationId, string text, CancellationToken cancellationToken) =>
        Task.FromResult(new FoundryTurn(conversationId ?? $"local-{Guid.NewGuid():N}", $"Local Foundry bridge received: {text}"));

    public Task<FoundryTurn> ContinueAsync(TenantIdentity identity, string conversationId, string taskId, string prompt, CancellationToken cancellationToken) =>
        Task.FromResult(new FoundryTurn(conversationId, $"Local continuation for {taskId}: {prompt}"));
}

public sealed class LocalTeamsGateway : ITeamsGateway
{
    public TenantIdentity CaptureIdentity(object activity) => new("local", "local-user", "local", "https://localhost", "{}");
    public Task SendProactiveAsync(TenantIdentity identity, string text, CancellationToken cancellationToken) => Task.CompletedTask;
}

public sealed class LocalGraphCalendarClient : IGraphCalendarClient
{
    public Task<object> AvailabilityAsync(TenantIdentity identity, CalendarAvailabilityRequest request, CancellationToken cancellationToken) =>
        Task.FromResult<object>(new { available = true, start = request.Start, end = request.End });
    public Task<object> CreateEventAsync(TenantIdentity identity, CalendarEventRequest request, CancellationToken cancellationToken) =>
        Task.FromResult<object>(new { id = Guid.NewGuid().ToString("N"), request.Subject });
    public Task<object> UpdateEventAsync(TenantIdentity identity, string eventId, CalendarEventRequest request, CancellationToken cancellationToken) =>
        Task.FromResult<object>(new { id = eventId, updated = true });
}
