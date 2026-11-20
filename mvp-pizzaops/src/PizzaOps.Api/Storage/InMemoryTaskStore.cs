using System.Collections.Concurrent;

namespace PizzaOps.Api.Storage;

public sealed class InMemoryTaskStore : ITaskStore
{
    private readonly ConcurrentDictionary<(string Tenant, string Id), DurableTask> _tasks = new();
    private readonly ConcurrentDictionary<(string Tenant, string Id), ApprovalRecord> _approvals = new();
    private readonly ConcurrentDictionary<(string Tenant, string Id), ProcessedTrigger> _triggers = new();
    private readonly ConcurrentDictionary<(string Tenant, string Id), IdempotencyRecord> _idempotency = new();
    private long _version;

    public Task<DurableTask> CreateAsync(DurableTask task, CancellationToken cancellationToken)
    {
        task.ETag = NewVersion();
        if (!_tasks.TryAdd((task.TenantId, task.Id), Clone(task)))
            throw new InvalidOperationException($"Task {task.Id} already exists.");
        return Task.FromResult(Clone(task));
    }

    public Task<DurableTask?> GetAsync(string tenantId, string taskId, CancellationToken cancellationToken) =>
        Task.FromResult(_tasks.TryGetValue((tenantId, taskId), out var task) ? Clone(task) : null);

    public Task<DurableTask?> GetByCalendarEventIdAsync(string tenantId, string eventId, CancellationToken cancellationToken) =>
        Task.FromResult(_tasks.Values.FirstOrDefault(task =>
            task.TenantId == tenantId && task.Type == "task" &&
            string.Equals(task.CalendarEventId, eventId, StringComparison.Ordinal)) is { } task
                ? Clone(task)
                : null);

    public Task<DurableTask?> GetByTeamsConversationIdAsync(string tenantId, string conversationId, CancellationToken cancellationToken) =>
        Task.FromResult(_tasks.Values.FirstOrDefault(task =>
            task.TenantId == tenantId && task.Type == "task" &&
            string.Equals(task.TeamsConversationId, conversationId, StringComparison.Ordinal)) is { } task
                ? Clone(task)
                : null);

    public Task<DurableTask> UpdateAsync(DurableTask task, string expectedETag, CancellationToken cancellationToken)
    {
        while (true)
        {
            if (!_tasks.TryGetValue((task.TenantId, task.Id), out var current))
                throw new KeyNotFoundException($"Task {task.Id} was not found.");
            if (!string.Equals(current.ETag, expectedETag, StringComparison.Ordinal))
                throw new ConcurrencyException("The task changed since it was read.");
            task.ETag = NewVersion();
            task.UpdatedAt = DateTimeOffset.UtcNow;
            if (_tasks.TryUpdate((task.TenantId, task.Id), Clone(task), current))
                return Task.FromResult(Clone(task));
        }
    }

    public Task<ApprovalRecord> CreateApprovalAsync(ApprovalRecord approval, CancellationToken cancellationToken)
    {
        approval.ETag = NewVersion();
        if (!_approvals.TryAdd((approval.TenantId, approval.Id), Clone(approval)))
            throw new InvalidOperationException($"Approval {approval.Id} already exists.");
        return Task.FromResult(Clone(approval));
    }

    public Task<ApprovalRecord?> GetApprovalAsync(string tenantId, string approvalId, CancellationToken cancellationToken) =>
        Task.FromResult(_approvals.TryGetValue((tenantId, approvalId), out var approval) ? Clone(approval) : null);

    public Task<ApprovalRecord> UpdateApprovalAsync(ApprovalRecord approval, string expectedETag, CancellationToken cancellationToken)
    {
        while (true)
        {
            if (!_approvals.TryGetValue((approval.TenantId, approval.Id), out var current))
                throw new KeyNotFoundException($"Approval {approval.Id} was not found.");
            if (!string.Equals(current.ETag, expectedETag, StringComparison.Ordinal))
                throw new ConcurrencyException("The approval changed since it was read.");
            approval.ETag = NewVersion();
            if (_approvals.TryUpdate((approval.TenantId, approval.Id), Clone(approval), current))
                return Task.FromResult(Clone(approval));
        }
    }

    public Task<bool> TryClaimTriggerAsync(string tenantId, string triggerId, CancellationToken cancellationToken)
    {
        var key = (tenantId, triggerId);
        var proposed = new ProcessedTrigger
        {
            Id = triggerId,
            TenantId = tenantId
        };
        if (_triggers.TryAdd(key, proposed))
            return Task.FromResult(true);

        while (_triggers.TryGetValue(key, out var current))
        {
            if (current.Completed || current.ClaimedUntil > DateTimeOffset.UtcNow)
                return Task.FromResult(false);
            if (_triggers.TryUpdate(key, proposed, current))
                return Task.FromResult(true);
        }
        return Task.FromResult(false);
    }

    public Task CompleteTriggerAsync(string tenantId, string triggerId, CancellationToken cancellationToken)
    {
        if (_triggers.TryGetValue((tenantId, triggerId), out var trigger))
        {
            trigger.Completed = true;
            trigger.CompletedAt = DateTimeOffset.UtcNow;
            return Task.CompletedTask;
        }
        throw new KeyNotFoundException($"Trigger {triggerId} was not found.");
    }

    public Task<bool> TryCreateIdempotencyAsync(string tenantId, string key, string operation, CancellationToken cancellationToken) =>
        Task.FromResult(_idempotency.TryAdd((tenantId, key), new IdempotencyRecord
        {
            Id = key,
            TenantId = tenantId,
            Operation = operation
        }));

    private string NewVersion() => Interlocked.Increment(ref _version).ToString();
    private static DurableTask Clone(DurableTask value) => new()
    {
        Id = value.Id, TenantId = value.TenantId, Title = value.Title, Description = value.Description,
        Type = value.Type, State = value.State, Status = value.Status, Identity = value.Identity,
        CreatedAt = value.CreatedAt, UpdatedAt = value.UpdatedAt, WakeAt = value.WakeAt,
        CalendarEventId = value.CalendarEventId, ETag = value.ETag,
        Objective = value.Objective, OwnerAadObjectId = value.OwnerAadObjectId,
        TeamsConversationId = value.TeamsConversationId, FoundryConversationId = value.FoundryConversationId,
        WorkshopStart = value.WorkshopStart, WorkshopEnd = value.WorkshopEnd, TimeZone = value.TimeZone,
        Headcount = value.Headcount, ApprovalIds = [.. value.ApprovalIds],
        NotificationIds = [.. value.NotificationIds], TriggerIds = [.. value.TriggerIds]
    };
    private static ApprovalRecord Clone(ApprovalRecord value) => new()
    {
        Id = value.Id, TenantId = value.TenantId, Type = value.Type, TaskId = value.TaskId,
        Action = value.Action, Reason = value.Reason, Approved = value.Approved,
        RequestedAt = value.RequestedAt, DecidedAt = value.DecidedAt, ETag = value.ETag,
        CanonicalInputHash = value.CanonicalInputHash, ExpiresAt = value.ExpiresAt
    };
}

public sealed class ConcurrencyException(string message) : InvalidOperationException(message);
