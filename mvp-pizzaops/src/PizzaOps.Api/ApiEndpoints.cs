using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PizzaOps.Api.Services;
using PizzaOps.Api.Storage;
using PizzaOps.Api.Security;

namespace PizzaOps.Api;

public static class ApiEndpoints
{
    public static void MapPizzaOps(this WebApplication app)
    {
        var tools = app.MapGroup("/v1");
        tools.RequireToolAuthorization();
        tools.MapPost("/tasks", CreateTask).WithName("createPizzaOpsTask");
        tools.MapGet("/tasks/{taskId}", GetTask).WithName("getPizzaOpsTask");
        tools.MapPatch("/tasks/{taskId}", UpdateTask).WithName("updatePizzaOpsTask");
        tools.MapPost("/planning/calculate", (DeliveryPlanRequest request, IDeliveryPlanner planner) =>
            Results.Ok(planner.Calculate(request))).WithName("calculatePizzaPlan");
        tools.MapPost("/calendar/availability", CalendarAvailability).WithName("getCalendarAvailability");
        tools.MapPost("/calendar/events", CreateCalendarEvent).WithName("createCalendarEvent");
        tools.MapPatch("/calendar/events/{eventId}", UpdateCalendarEvent).WithName("updateCalendarEvent");
        tools.MapPost("/policy/check", (PolicyDecisionRequest request, IPolicyService policy) =>
            Results.Ok(policy.Decide(request))).WithName("checkPolicy");
        tools.MapPost("/approvals", RequestApproval).WithName("requestApproval");
        tools.MapPost("/approvals/{approvalId}/decision", DecideApproval).WithName("decideApproval");
        tools.MapPost("/wakeups", ScheduleWakeup).WithName("scheduleWakeup");
        tools.MapPost("/notifications", CreateNotification).WithName("createNotification");
        app.MapPost("/webhooks/graph", GraphWebhook).ExcludeFromDescription();
        app.MapPost("/api/graph/notifications", GraphWebhook).ExcludeFromDescription();
    }

    private static async Task<IResult> CreateTask(CreateTaskRequest request, ITaskStore store, CancellationToken cancellationToken)
    {
        if (!await store.TryCreateIdempotencyAsync(request.TenantId, request.IdempotencyKey, "create-task", cancellationToken))
            return Results.Conflict(new { message = "idempotencyKey is already in use." });
        var task = await store.GetByTeamsConversationIdAsync(request.TenantId, request.ConversationId, cancellationToken);
        if (task is null)
        {
            task = await store.CreateAsync(new DurableTask
            {
                Id = Guid.NewGuid().ToString("N"),
                TenantId = request.TenantId,
                OwnerAadObjectId = request.OwnerAadObjectId,
                Title = request.Objective,
                Objective = request.Objective,
                TeamsConversationId = request.ConversationId,
                WorkshopStart = request.WorkshopStart,
                WorkshopEnd = request.WorkshopEnd,
                TimeZone = request.TimeZone,
                Headcount = request.Headcount,
                State = TaskState.Planned
            }, cancellationToken);
        }
        else
        {
            task.OwnerAadObjectId = request.OwnerAadObjectId;
            task.Title = request.Objective;
            task.Objective = request.Objective;
            task.WorkshopStart = request.WorkshopStart;
            task.WorkshopEnd = request.WorkshopEnd;
            task.TimeZone = request.TimeZone;
            task.Headcount = request.Headcount;
            task = await store.UpdateAsync(task, task.ETag!, cancellationToken);
        }
        return Results.Created($"/v1/tasks/{task.Id}", task);
    }

    private static async Task<IResult> GetTask(string taskId, string tenantId, ITaskStore store, CancellationToken cancellationToken)
    {
        var task = await store.GetAsync(tenantId, taskId, cancellationToken);
        return task is null ? Results.NotFound() : Results.Ok(task);
    }

    private static async Task<IResult> UpdateTask(string taskId, UpdateTaskRequest request, ITaskStore store, CancellationToken cancellationToken)
    {
        var task = await store.GetAsync(request.TenantId, taskId, cancellationToken);
        if (task is null) return Results.NotFound();
        if (request.State is { } state) task.State = state;
        if (request.Status is not null) task.Status = request.Status;
        if (request.WakeAt is not null) task.WakeAt = request.WakeAt;
        if (request.Headcount is not null) task.Headcount = request.Headcount;
        try
        {
            return Results.Ok(await store.UpdateAsync(task, request.ETag, cancellationToken));
        }
        catch (ConcurrencyException ex)
        {
            return Results.Conflict(new ConcurrencyConflict(ex.Message));
        }
    }

    private static async Task<IResult> CalendarAvailability(CalendarAvailabilityRequest request, IGraphCalendarClient graph,
        ITaskStore store, CancellationToken cancellationToken)
    {
        var task = await store.GetAsync(request.TenantId, request.TaskId, cancellationToken);
        if (task?.Identity is null) return Results.NotFound();
        return Results.Ok(await graph.AvailabilityAsync(task.Identity, request, cancellationToken));
    }

    private static async Task<IResult> CreateCalendarEvent(CalendarEventRequest request, IGraphCalendarClient graph,
        ITaskStore store, CancellationToken cancellationToken)
    {
        var task = await store.GetAsync(request.TenantId, request.TaskId, cancellationToken);
        if (task?.Identity is null) return Results.NotFound();
        var canonicalInput = new
        {
            operation = "create-meeting",
            request.TaskId,
            request.Subject,
            request.Start,
            request.End,
            request.TimeZone,
            request.Attendees
        };
        var policyResult = RequireApprovedMaterialAction("create-meeting", request.TaskId,
            request.ApprovalId, canonicalInput, request.TenantId, store, cancellationToken);
        var failure = await policyResult;
        if (failure is not null) return failure;
        if (!await store.TryCreateIdempotencyAsync(request.TenantId, request.IdempotencyKey, "create-calendar-event", cancellationToken))
            return Results.Conflict(new { message = "idempotencyKey is already in use." });
        var result = await graph.CreateEventAsync(task.Identity, request, cancellationToken);
        var eventId = JsonSerializer.SerializeToElement(result).TryGetProperty("id", out var id)
            ? id.GetString()
            : null;
        if (!string.IsNullOrWhiteSpace(eventId))
        {
            task.CalendarEventId = eventId;
            await store.UpdateAsync(task, task.ETag!, cancellationToken);
        }
        return Results.Ok(result);
    }

    private static async Task<IResult> UpdateCalendarEvent(string eventId, CalendarEventRequest request, IGraphCalendarClient graph,
        ITaskStore store, CancellationToken cancellationToken)
    {
        var task = await store.GetAsync(request.TenantId, request.TaskId, cancellationToken);
        if (task?.Identity is null) return Results.NotFound();
        var canonicalInput = new
        {
            operation = "update-meeting",
            request.TaskId,
            eventId,
            request.Subject,
            request.Start,
            request.End,
            request.TimeZone,
            request.Attendees
        };
        var failure = await RequireApprovedMaterialAction("update-meeting", request.TaskId,
            request.ApprovalId, canonicalInput, request.TenantId, store, cancellationToken);
        if (failure is not null) return failure;
        if (!await store.TryCreateIdempotencyAsync(request.TenantId, request.IdempotencyKey, "update-calendar-event", cancellationToken))
            return Results.Conflict(new { message = "idempotencyKey is already in use." });
        var result = await graph.UpdateEventAsync(task.Identity, eventId, request, cancellationToken);
        task.CalendarEventId = eventId;
        await store.UpdateAsync(task, task.ETag!, cancellationToken);
        return Results.Ok(result);
    }

    private static async Task<IResult?> RequireApprovedMaterialAction(
        string action,
        string taskId,
        string approvalId,
        object canonicalInput,
        string tenantId,
        ITaskStore store,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(approvalId))
            return Results.Problem("A human approvalId is required for this action.", statusCode: StatusCodes.Status403Forbidden);
        var approval = await store.GetApprovalAsync(tenantId, approvalId, cancellationToken);
        var expectedHash = CanonicalHash(JsonSerializer.SerializeToElement(canonicalInput));
        var valid = approval is { Approved: true } &&
                    approval.TaskId == taskId &&
                    approval.Action.Equals(action, StringComparison.OrdinalIgnoreCase) &&
                    approval.ExpiresAt > DateTimeOffset.UtcNow &&
                    FixedTimeEquals(approval.CanonicalInputHash, expectedHash);
        return valid
            ? null
            : Results.Problem("The approvalId is invalid, expired, or bound to different input.",
                statusCode: StatusCodes.Status403Forbidden);
    }

    private static async Task<IResult> RequestApproval(ApprovalRequest request, ITaskStore store, CancellationToken cancellationToken)
    {
        if (!await store.TryCreateIdempotencyAsync(request.TenantId, request.IdempotencyKey, "request-approval", cancellationToken))
            return Results.Conflict(new { message = "idempotencyKey is already in use." });
        var approval = await store.CreateApprovalAsync(new ApprovalRecord
        {
            TenantId = request.TenantId,
            TaskId = request.TaskId,
            Action = request.Operation,
            Reason = request.Summary,
            CanonicalInputHash = CanonicalHash(request.CanonicalInput),
            ExpiresAt = request.ExpiresAt ?? DateTimeOffset.UtcNow.AddHours(8)
        }, cancellationToken);
        var task = await store.GetAsync(request.TenantId, request.TaskId, cancellationToken);
        if (task is not null)
        {
            task.ApprovalIds.Add(approval.Id);
            await store.UpdateAsync(task, task.ETag!, cancellationToken);
        }
        return Results.Created($"/v1/approvals/{approval.Id}", approval);
    }

    private static async Task<IResult> DecideApproval(string approvalId, ApprovalDecisionRequest request, ITaskStore store,
        CancellationToken cancellationToken)
    {
        var approval = await store.GetApprovalAsync(request.TenantId, approvalId, cancellationToken);
        if (approval is null) return Results.NotFound();
        if (!FixedTimeEquals(approval.CanonicalInputHash, request.CanonicalInputHash))
            return Results.Problem("The canonical input hash does not match the approval request.",
                statusCode: StatusCodes.Status409Conflict);
        var etag = approval.ETag ?? throw new InvalidOperationException("Approval is missing an ETag.");
        approval.Approved = request.Approved;
        approval.DecidedAt = DateTimeOffset.UtcNow;
        if (!request.Approved) approval.Reason = request.Reason ?? approval.Reason;
        try { return Results.Ok(await store.UpdateApprovalAsync(approval, etag, cancellationToken)); }
        catch (ConcurrencyException ex) { return Results.Conflict(new ConcurrencyConflict(ex.Message)); }
    }

    private static async Task<IResult> ScheduleWakeup(ScheduleWakeupRequest request, IWakeupScheduler scheduler,
        ITaskStore store, CancellationToken cancellationToken)
    {
        var task = await store.GetAsync(request.TenantId, request.TaskId, cancellationToken);
        if (task is null) return Results.NotFound();
        var triggerId = await scheduler.ScheduleAsync(request.TenantId, request.TaskId, request.DueAt, request.Reason,
            request.IdempotencyKey, cancellationToken);
        task.TriggerIds.Add(triggerId);
        task.WakeAt = request.DueAt;
        await store.UpdateAsync(task, task.ETag!, cancellationToken);
        return Results.Accepted(value: new { taskId = request.TaskId, triggerId, wakeAt = request.DueAt });
    }

    private static async Task<IResult> CreateNotification(NotificationRequest request, ITeamsGateway teams, ITaskStore store,
        CancellationToken cancellationToken)
    {
        var task = await store.GetAsync(request.TenantId, request.TaskId, cancellationToken);
        if (task?.Identity is null) return Results.NotFound();
        if (!await store.TryCreateIdempotencyAsync(request.TenantId, request.IdempotencyKey, "notification", cancellationToken))
            return Results.Conflict(new { message = "idempotencyKey is already in use." });
        await teams.SendProactiveAsync(task.Identity, request.Text, cancellationToken);
        task.NotificationIds.Add(request.IdempotencyKey);
        await store.UpdateAsync(task, task.ETag!, cancellationToken);
        return Results.Accepted(value: new { notificationId = request.IdempotencyKey });
    }

    private static async Task<IResult> GraphWebhook(HttpRequest httpRequest, PizzaOpsOptions options, IWakeupScheduler scheduler,
        ITaskStore store,
        CancellationToken cancellationToken)
    {
        if (httpRequest.Query.TryGetValue("validationToken", out var validationToken))
            return Results.Text(validationToken.ToString(), "text/plain");
        if (string.IsNullOrWhiteSpace(options.GraphWebhookClientState))
            return Results.Problem("Graph webhook clientState is not configured.", statusCode: 503);
        using var document = await JsonDocument.ParseAsync(httpRequest.Body, cancellationToken: cancellationToken);
        foreach (var value in document.RootElement.GetProperty("value").EnumerateArray())
        {
            var clientState = value.GetProperty("clientState").GetString();
            if (!FixedTimeEquals(clientState, options.GraphWebhookClientState))
                return Results.Unauthorized();
            var tenantId = value.GetProperty("tenantId").GetString() ?? throw new InvalidDataException("tenantId is required.");
            var subscriptionId = value.GetProperty("subscriptionId").GetString() ?? Guid.NewGuid().ToString("N");
            if (!value.TryGetProperty("resourceData", out var data) ||
                !data.TryGetProperty("id", out var eventIdElement) ||
                eventIdElement.GetString() is not { } eventId)
                continue;
            var task = await store.GetByCalendarEventIdAsync(tenantId, eventId, cancellationToken);
            if (task is null)
                continue;
            var rawNotification = value.GetRawText();
            var key = $"graph-{Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(rawNotification)))}";
            await scheduler.ScheduleAsync(tenantId, task.Id, DateTimeOffset.UtcNow,
                $"Calendar changed: {value.GetProperty("resource").GetString()}", key, cancellationToken);
        }
        return Results.Accepted();
    }

    private static bool FixedTimeEquals(string? left, string right)
    {
        if (left is null) return false;
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        return leftBytes.Length == rightBytes.Length &&
               CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
    }

    private static string CanonicalHash(JsonElement input)
    {
        var node = JsonNode.Parse(input.GetRawText())
            ?? throw new ArgumentException("Canonical input must be valid JSON.");
        var normalized = Normalize(node);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized.ToJsonString())));
    }

    private static JsonNode Normalize(JsonNode node)
    {
        if (node is JsonObject obj)
        {
            var normalized = new JsonObject();
            foreach (var property in obj.OrderBy(pair => pair.Key, StringComparer.Ordinal))
                normalized[property.Key] = property.Value is null ? null : Normalize(property.Value.DeepClone());
            return normalized;
        }
        if (node is JsonArray array)
            return new JsonArray(array.Select(item => item is null ? null : Normalize(item.DeepClone())).ToArray());
        return node.DeepClone();
    }
}
