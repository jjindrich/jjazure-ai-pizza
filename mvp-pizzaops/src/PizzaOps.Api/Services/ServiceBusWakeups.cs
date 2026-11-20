using System.Text.Json;
using Azure.Messaging.ServiceBus;
using PizzaOps.Api.Storage;

namespace PizzaOps.Api.Services;

public sealed class ServiceBusWakeupScheduler(
    ServiceBusSender sender,
    ITaskStore store) : IWakeupScheduler
{
    public async Task<string> ScheduleAsync(string tenantId, string taskId, DateTimeOffset wakeAt, string prompt,
        string idempotencyKey, CancellationToken cancellationToken)
    {
        var triggerId = $"wakeup-{idempotencyKey}";
        var message = new ServiceBusMessage(BinaryData.FromObjectAsJson(new WakeupMessage(
            triggerId, tenantId, taskId, prompt, wakeAt)))
        {
            MessageId = triggerId,
            CorrelationId = taskId,
            Subject = "pizzaops-wakeup"
        };
        await sender.ScheduleMessageAsync(message, wakeAt, cancellationToken);
        await store.TryCreateIdempotencyAsync(tenantId, idempotencyKey, "schedule-wakeup", cancellationToken);
        return triggerId;
    }

    public bool IsPastDue(DateTimeOffset wakeAt, DateTimeOffset now) => wakeAt <= now;
}

public sealed class InMemoryWakeupScheduler(ITaskStore store) : IWakeupScheduler
{
    public async Task<string> ScheduleAsync(string tenantId, string taskId, DateTimeOffset wakeAt, string prompt,
        string idempotencyKey, CancellationToken cancellationToken)
    {
        var triggerId = $"wakeup-{idempotencyKey}";
        await store.TryCreateIdempotencyAsync(tenantId, idempotencyKey, "schedule-wakeup", cancellationToken);
        return triggerId;
    }

    public bool IsPastDue(DateTimeOffset wakeAt, DateTimeOffset now) => wakeAt <= now;
}

public sealed class WakeupWorker(
    ServiceBusProcessor processor,
    ITaskStore store,
    IFoundryBridge foundry,
    ITeamsGateway teams,
    ILogger<WakeupWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        processor.ProcessMessageAsync += ProcessAsync;
        processor.ProcessErrorAsync += args =>
        {
            logger.LogError(args.Exception, "Service Bus wakeup processing failed");
            return Task.CompletedTask;
        };
        await processor.StartProcessingAsync(stoppingToken);
        try
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally
        {
            await processor.StopProcessingAsync(CancellationToken.None);
        }
    }

    private async Task ProcessAsync(ProcessMessageEventArgs args)
    {
        var wakeup = args.Message.Body.ToObjectFromJson<WakeupMessage>()
            ?? throw new InvalidDataException("Wakeup message body is invalid.");
        if (!await store.TryClaimTriggerAsync(wakeup.TenantId, wakeup.TriggerId, args.CancellationToken))
        {
            await args.CompleteMessageAsync(args.Message, args.CancellationToken);
            return;
        }

        var task = await store.GetAsync(wakeup.TenantId, wakeup.TaskId, args.CancellationToken)
            ?? throw new KeyNotFoundException($"Task {wakeup.TaskId} was not found.");
        var identity = task.Identity ?? throw new InvalidOperationException("Task has no Agentic User identity.");
        var conversationId = task.FoundryConversationId
            ?? throw new InvalidOperationException("Task has no Foundry conversation.");
        var response = await foundry.ContinueAsync(identity, conversationId, task.Id, wakeup.Prompt, args.CancellationToken);
        await teams.SendProactiveAsync(identity, response.Text, args.CancellationToken);
        await store.CompleteTriggerAsync(wakeup.TenantId, wakeup.TriggerId, args.CancellationToken);
        await args.CompleteMessageAsync(args.Message, args.CancellationToken);
    }
}
