namespace PizzaOps.Api.Services;

public interface IPolicyService
{
    PolicyDecision Decide(PolicyDecisionRequest request);
}

public sealed class PolicyService : IPolicyService
{
    private static readonly HashSet<string> SafeActions =
        ["read", "availability", "plan", "calculate", "task.read", "task.update", "notification", "notify", "wakeup.schedule"];

    public PolicyDecision Decide(PolicyDecisionRequest request)
    {
        var action = request.Operation.Trim().ToLowerInvariant();
        if (request.HasFinancialImpact || ContainsAny(action, "pay", "payment", "purchase", "checkout", "charge", "refund", "financial", "transfer", "bank", "credit card"))
            return new(PolicyEffect.Deny, "Payment and financial transactions are prohibited.");

        if (SafeActions.Any(safe => action == safe || action.StartsWith($"{safe}.", StringComparison.Ordinal)))
            return new(PolicyEffect.Permit, "Read-only, planning, availability, and notification actions are autonomous.");

        if (request.AffectsOtherUsers || ContainsAny(action, "create-meeting", "update-meeting", "invite", "calendar.write", "send", "delete"))
            return new(PolicyEffect.ApprovalRequired, "Material actions and actions affecting others require approval.");

        return new(PolicyEffect.ApprovalRequired, "The action is not in the autonomous allow-list.");
    }

    private static bool ContainsAny(string text, params string[] values) =>
        values.Any(value => text.Contains(value, StringComparison.OrdinalIgnoreCase));
}
