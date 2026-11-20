using System.Net;
using Microsoft.Azure.Cosmos;

namespace PizzaOps.Api.Storage;

public sealed class CosmosTaskStore(CosmosClient client, PizzaOpsOptions options) : ITaskStore
{
    private Container Tasks => client
        .GetDatabase(options.CosmosDatabase!)
        .GetContainer(options.CosmosTasksContainer);
    private Container Events => client
        .GetDatabase(options.CosmosDatabase!)
        .GetContainer(options.CosmosEventsContainer);

    public async Task<DurableTask> CreateAsync(DurableTask task, CancellationToken cancellationToken) =>
        (await Tasks.CreateItemAsync(task, new PartitionKey(task.TenantId), cancellationToken: cancellationToken)).Resource;

    public async Task<DurableTask?> GetAsync(string tenantId, string taskId, CancellationToken cancellationToken)
    {
        try
        {
            return (await Tasks.ReadItemAsync<DurableTask>(taskId, new PartitionKey(tenantId), cancellationToken: cancellationToken)).Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    public async Task<DurableTask?> GetByCalendarEventIdAsync(string tenantId, string eventId, CancellationToken cancellationToken)
    {
        var definition = new QueryDefinition(
                "SELECT TOP 1 * FROM c WHERE c.type = @type AND c.calendarEventId = @eventId")
            .WithParameter("@type", "task")
            .WithParameter("@eventId", eventId);
        using var iterator = Tasks.GetItemQueryIterator<DurableTask>(
            definition, requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(tenantId) });
        return iterator.HasMoreResults
            ? (await iterator.ReadNextAsync(cancellationToken)).FirstOrDefault()
            : null;
    }

    public async Task<DurableTask?> GetByTeamsConversationIdAsync(string tenantId, string conversationId, CancellationToken cancellationToken)
    {
        var definition = new QueryDefinition(
                "SELECT TOP 1 * FROM c WHERE c.type = @type AND c.teamsConversationId = @conversationId")
            .WithParameter("@type", "task")
            .WithParameter("@conversationId", conversationId);
        using var iterator = Tasks.GetItemQueryIterator<DurableTask>(
            definition, requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(tenantId) });
        return iterator.HasMoreResults
            ? (await iterator.ReadNextAsync(cancellationToken)).FirstOrDefault()
            : null;
    }

    public async Task<DurableTask> UpdateAsync(DurableTask task, string expectedETag, CancellationToken cancellationToken)
    {
        try
        {
            task.UpdatedAt = DateTimeOffset.UtcNow;
            return (await Tasks.ReplaceItemAsync(task, task.Id, new PartitionKey(task.TenantId),
                new ItemRequestOptions { IfMatchEtag = expectedETag }, cancellationToken)).Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.PreconditionFailed)
        {
            throw new ConcurrencyException("The task changed since it was read.");
        }
    }

    public async Task<ApprovalRecord> CreateApprovalAsync(ApprovalRecord approval, CancellationToken cancellationToken) =>
        (await Tasks.CreateItemAsync(approval, new PartitionKey(approval.TenantId), cancellationToken: cancellationToken)).Resource;

    public async Task<ApprovalRecord?> GetApprovalAsync(string tenantId, string approvalId, CancellationToken cancellationToken)
    {
        try
        {
            return (await Tasks.ReadItemAsync<ApprovalRecord>(approvalId, new PartitionKey(tenantId), cancellationToken: cancellationToken)).Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    public async Task<ApprovalRecord> UpdateApprovalAsync(ApprovalRecord approval, string expectedETag, CancellationToken cancellationToken)
    {
        try
        {
            return (await Tasks.ReplaceItemAsync(approval, approval.Id, new PartitionKey(approval.TenantId),
                new ItemRequestOptions { IfMatchEtag = expectedETag }, cancellationToken)).Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.PreconditionFailed)
        {
            throw new ConcurrencyException("The approval changed since it was read.");
        }
    }

    public async Task<bool> TryClaimTriggerAsync(string tenantId, string triggerId, CancellationToken cancellationToken)
    {
        var trigger = new ProcessedTrigger { Id = triggerId, TenantId = tenantId };
        try
        {
            await Events.CreateItemAsync(trigger, new PartitionKey(tenantId), cancellationToken: cancellationToken);
            return true;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
        {
            var current = (await Events.ReadItemAsync<ProcessedTrigger>(
                triggerId, new PartitionKey(tenantId), cancellationToken: cancellationToken)).Resource;
            if (current.Completed || current.ClaimedUntil > DateTimeOffset.UtcNow)
                return false;
            try
            {
                current.ClaimedUntil = DateTimeOffset.UtcNow.AddMinutes(2);
                await Events.ReplaceItemAsync(current, triggerId, new PartitionKey(tenantId),
                    new ItemRequestOptions { IfMatchEtag = current.ETag }, cancellationToken);
                return true;
            }
            catch (CosmosException conflict) when (conflict.StatusCode == HttpStatusCode.PreconditionFailed)
            {
                return false;
            }
        }
    }

    public async Task CompleteTriggerAsync(string tenantId, string triggerId, CancellationToken cancellationToken)
    {
        var response = await Events.ReadItemAsync<ProcessedTrigger>(
            triggerId, new PartitionKey(tenantId), cancellationToken: cancellationToken);
        var trigger = response.Resource;
        trigger.Completed = true;
        trigger.CompletedAt = DateTimeOffset.UtcNow;
        await Events.ReplaceItemAsync(trigger, triggerId, new PartitionKey(tenantId),
            new ItemRequestOptions { IfMatchEtag = trigger.ETag }, cancellationToken);
    }

    public async Task<bool> TryCreateIdempotencyAsync(string tenantId, string key, string operation, CancellationToken cancellationToken) =>
        await TryCreateAsync(Events, new IdempotencyRecord { Id = key, TenantId = tenantId, Operation = operation }, cancellationToken);

    private static async Task<bool> TryCreateAsync<T>(Container container, T item, CancellationToken cancellationToken)
    {
        try
        {
            await container.CreateItemAsync(item, cancellationToken: cancellationToken);
            return true;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
        {
            return false;
        }
    }
}
