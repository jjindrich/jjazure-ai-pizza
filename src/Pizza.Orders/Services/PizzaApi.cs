using Pizza.Contracts;

namespace Pizza.Orders.Services;

public static class PizzaApi
{
    public static void MapPizzaApi(this WebApplication app)
    {
        var orders = app.MapGroup("/api/orders").WithTags("Pizza orders").RequireRateLimiting("pizza-api");
        orders.MapGet("/", async (OrderService service, CancellationToken token) =>
            Results.Ok(await service.GetAllAsync(token)));
        orders.MapGet("/{id:guid}", async (Guid id, OrderService service, CancellationToken token) =>
        {
            var order = await service.GetAsync(id, token);
            return order is null ? Results.NotFound() : Results.Ok(order);
        });
        orders.MapPost("/", async (
            CreateOrderRequest request, OrderService service, CancellationToken token) =>
        {
            try
            {
                var order = await service.CreateAsync(request, token);
                return Results.Created($"/api/orders/{order.Id}", order);
            }
            catch (OrderValidationException exception)
            {
                return Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["request"] = [exception.Message]
                });
            }
            catch (CatalogUnavailableException)
            {
                return Results.Problem(
                    statusCode: StatusCodes.Status503ServiceUnavailable,
                    title: "Catalog unavailable",
                    detail: "The order was not created. Please retry when the catalog is available.");
            }
        });
        orders.MapPut("/{id:guid}/status", async (
            Guid id, UpdateOrderStatusRequest request, OrderService service, CancellationToken token) =>
        {
            try
            {
                var order = await service.UpdateStatusAsync(id, request.Status, token);
                return order is null ? Results.NotFound() : Results.Ok(order);
            }
            catch (OrderValidationException exception)
            {
                return Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["status"] = [exception.Message]
                });
            }
        });
    }
}
