namespace PizzaOps.Api.Services;

public interface IDeliveryPlanner
{
    DeliveryPlan Calculate(DeliveryPlanRequest request);
}

public sealed class DeliveryPlanner : IDeliveryPlanner
{
    public DeliveryPlan Calculate(DeliveryPlanRequest request)
    {
        if (request.ExpectedDeliveryMinutes is < 1 or > 240)
            throw new ArgumentOutOfRangeException(nameof(request.ExpectedDeliveryMinutes), "Expected delivery must be between 1 and 240 minutes.");
        if (request.ServingBufferMinutes is < 0 or > 120)
            throw new ArgumentOutOfRangeException(nameof(request.ServingBufferMinutes), "Serving buffer must be between 0 and 120 minutes.");
        if (request.PreparationBufferMinutes is < 0 or > 120)
            throw new ArgumentOutOfRangeException(nameof(request.PreparationBufferMinutes), "Preparation buffer must be between 0 and 120 minutes.");
        if (string.IsNullOrWhiteSpace(request.TimeZone))
            throw new ArgumentException("Time zone is required.", nameof(request.TimeZone));

        var targetArrival = request.LunchStart.AddMinutes(-request.ServingBufferMinutes);
        var orderDeadline = targetArrival.AddMinutes(
            -(request.ExpectedDeliveryMinutes + request.PreparationBufferMinutes));
        return new(request.LunchStart, targetArrival, orderDeadline, request.ExpectedDeliveryMinutes, request.TimeZone);
    }
}
