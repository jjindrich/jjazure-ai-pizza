namespace PizzaOps.Api.Storage;

public interface ITaskStore
{
    Task<DurableTask> CreateAsync(DurableTask task, CancellationToken cancellationToken);
    Task<DurableTask?> GetAsync(string tenantId, string taskId, CancellationToken cancellationToken);
    Task<DurableTask?> GetByCalendarEventIdAsync(string tenantId, string eventId, CancellationToken cancellationToken);
    Task<DurableTask?> GetByTeamsConversationIdAsync(string tenantId, string conversationId, CancellationToken cancellationToken);
    Task<DurableTask> UpdateAsync(DurableTask task, string expectedETag, CancellationToken cancellationToken);
    Task<ApprovalRecord> CreateApprovalAsync(ApprovalRecord approval, CancellationToken cancellationToken);
    Task<ApprovalRecord?> GetApprovalAsync(string tenantId, string approvalId, CancellationToken cancellationToken);
    Task<ApprovalRecord> UpdateApprovalAsync(ApprovalRecord approval, string expectedETag, CancellationToken cancellationToken);
    Task<bool> TryClaimTriggerAsync(string tenantId, string triggerId, CancellationToken cancellationToken);
    Task CompleteTriggerAsync(string tenantId, string triggerId, CancellationToken cancellationToken);
    Task<bool> TryCreateIdempotencyAsync(string tenantId, string key, string operation, CancellationToken cancellationToken);
}
