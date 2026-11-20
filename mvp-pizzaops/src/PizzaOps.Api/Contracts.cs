using System.Text.Json.Serialization;
using System.Text.Json;
using Newtonsoft.Json;

namespace PizzaOps.Api;

public enum TaskState { Planned, Running, WaitingForApproval, Scheduled, Completed, Failed }
public enum PolicyEffect { Permit, ApprovalRequired, Deny }

public sealed record TenantIdentity(
    string TenantId,
    string AadObjectId,
    string ConversationId,
    string ServiceUrl,
    string AgenticIdentity);

public sealed record CreateTaskRequest(
    string TenantId,
    string OwnerAadObjectId,
    string Objective,
    string ConversationId,
    string IdempotencyKey,
    DateTimeOffset? WorkshopStart = null,
    DateTimeOffset? WorkshopEnd = null,
    string? TimeZone = null,
    int? Headcount = null);
public sealed record UpdateTaskRequest(
    string TenantId,
    string ETag,
    string IdempotencyKey,
    TaskState? State = null,
    string? Status = null,
    DateTimeOffset? WakeAt = null,
    int? Headcount = null,
    JsonElement? Patch = null);
public sealed record DeliveryPlanRequest(
    DateTimeOffset LunchStart,
    string TimeZone,
    int ExpectedDeliveryMinutes,
    int ServingBufferMinutes = 5,
    int PreparationBufferMinutes = 0,
    string IdempotencyKey = "");
public sealed record DeliveryPlan(
    DateTimeOffset LunchStart,
    DateTimeOffset TargetArrival,
    DateTimeOffset OrderDeadline,
    int ExpectedDeliveryMinutes,
    string TimeZone);
public sealed record CalendarAvailabilityRequest(
    string TenantId,
    string TaskId,
    DateTimeOffset Start,
    DateTimeOffset End,
    string TimeZone,
    int DurationMinutes,
    string IdempotencyKey);
public sealed record CalendarEventRequest(
    string TenantId,
    string TaskId,
    string Subject,
    DateTimeOffset Start,
    DateTimeOffset End,
    string TimeZone,
    string[] Attendees,
    string ApprovalId,
    string IdempotencyKey);
public sealed record PolicyDecisionRequest(
    string TaskId,
    string Operation,
    bool AffectsOtherUsers,
    bool HasFinancialImpact);
public sealed record PolicyDecision(PolicyEffect Effect, string Reason);
public sealed record ApprovalRequest(
    string TenantId,
    string TaskId,
    string Operation,
    string Summary,
    JsonElement CanonicalInput,
    DateTimeOffset? ExpiresAt,
    string IdempotencyKey);
public sealed record ApprovalDecisionRequest(
    string TenantId,
    bool Approved,
    string DecidedBy,
    string CanonicalInputHash,
    string? Reason = null);
public sealed record NotificationRequest(
    string TenantId,
    string TaskId,
    string Text,
    string Reason,
    string IdempotencyKey);
public sealed record ScheduleWakeupRequest(
    string TenantId,
    string TaskId,
    DateTimeOffset DueAt,
    string Reason,
    string IdempotencyKey);
public sealed record GraphWebhookSubscription(string ClientState);

public sealed class DurableTask
{
    [JsonProperty("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    [JsonProperty("tenantId")]
    public string TenantId { get; set; } = "";
    [JsonProperty("type")]
    public string Type { get; set; } = "task";
    public string Title { get; set; } = "";
    public string? Description { get; set; }
    public TaskState State { get; set; } = TaskState.Planned;
    public string? Status { get; set; }
    public string? Objective { get; set; }
    public string? OwnerAadObjectId { get; set; }
    public string? TeamsConversationId { get; set; }
    public string? FoundryConversationId { get; set; }
    public DateTimeOffset? WorkshopStart { get; set; }
    public DateTimeOffset? WorkshopEnd { get; set; }
    public string? TimeZone { get; set; }
    public int? Headcount { get; set; }
    public List<string> ApprovalIds { get; set; } = [];
    public List<string> NotificationIds { get; set; } = [];
    public List<string> TriggerIds { get; set; } = [];
    public TenantIdentity? Identity { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? WakeAt { get; set; }
    [JsonProperty("calendarEventId")]
    public string? CalendarEventId { get; set; }
    [JsonPropertyName("_etag")]
    [JsonProperty("_etag")]
    public string? ETag { get; set; }
}

public sealed class ApprovalRecord
{
    [JsonProperty("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    [JsonProperty("tenantId")]
    public string TenantId { get; set; } = "";
    [JsonProperty("type")]
    public string Type { get; set; } = "approval";
    public string TaskId { get; set; } = "";
    public string Action { get; set; } = "";
    public string Reason { get; set; } = "";
    public string CanonicalInputHash { get; set; } = "";
    public DateTimeOffset? ExpiresAt { get; set; }
    public bool? Approved { get; set; }
    public DateTimeOffset RequestedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? DecidedAt { get; set; }
    [JsonPropertyName("_etag")]
    [JsonProperty("_etag")]
    public string? ETag { get; set; }
}

public sealed class ProcessedTrigger
{
    [JsonProperty("id")]
    public string Id { get; set; } = "";
    [JsonProperty("tenantId")]
    public string TenantId { get; set; } = "";
    [JsonProperty("type")]
    public string Type { get; set; } = "processed-trigger";
    public DateTimeOffset ClaimedUntil { get; set; } = DateTimeOffset.UtcNow.AddMinutes(2);
    public bool Completed { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
    [JsonPropertyName("_etag")]
    [JsonProperty("_etag")]
    public string? ETag { get; set; }
}

public sealed class IdempotencyRecord
{
    [JsonProperty("id")]
    public string Id { get; set; } = "";
    [JsonProperty("tenantId")]
    public string TenantId { get; set; } = "";
    [JsonProperty("type")]
    public string Type { get; set; } = "idempotency";
    public string Operation { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed record WakeupMessage(
    string TriggerId,
    string TenantId,
    string TaskId,
    string Prompt,
    DateTimeOffset WakeAt);

public sealed record FoundryTurn(string ConversationId, string Text);

public sealed record ConcurrencyConflict(string Message);
public sealed record NotFound(string Message);
