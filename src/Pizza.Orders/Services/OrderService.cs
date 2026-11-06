using Pizza.Contracts;

namespace Pizza.Orders.Services;

public sealed class OrderService(
    IOrderStore orders,
    IPizzaCatalogReader catalog,
    TimeProvider timeProvider)
{
    public Task<IReadOnlyList<PizzaOrder>> GetAllAsync(CancellationToken cancellationToken) =>
        orders.GetAllAsync(cancellationToken);

    public Task<PizzaOrder?> GetAsync(Guid id, CancellationToken cancellationToken) =>
        orders.GetAsync(id, cancellationToken);

    public async Task<PizzaOrder> CreateAsync(
        CreateOrderRequest request,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.CustomerName) || request.CustomerName.Trim().Length > 120)
        {
            throw new OrderValidationException("Customer name is required and must be 120 characters or fewer.");
        }

        if (string.IsNullOrWhiteSpace(request.CustomerAddress) || request.CustomerAddress.Trim().Length > 500)
        {
            throw new OrderValidationException("Delivery address is required and must be 500 characters or fewer.");
        }

        if (request.Items is null || request.Items.Count is < 1 or > 20)
        {
            throw new OrderValidationException("An order must contain between 1 and 20 pizza items.");
        }

        var lines = new List<OrderLine>(request.Items.Count);
        foreach (var requestedItem in request.Items)
        {
            if (requestedItem.Quantity is < 1 or > 50)
            {
                throw new OrderValidationException("Each quantity must be between 1 and 50.");
            }

            var pizza = await catalog.GetAsync(requestedItem.PizzaId, cancellationToken);
            if (pizza is null || !pizza.IsAvailable)
            {
                throw new OrderValidationException($"Pizza '{requestedItem.PizzaId}' is unavailable.");
            }

            lines.Add(new OrderLine(pizza.Id, pizza.Name, pizza.Price, requestedItem.Quantity));
        }

        var order = new PizzaOrder(
            Guid.NewGuid(),
            new Customer(request.CustomerName.Trim(), request.CustomerAddress.Trim()),
            lines,
            OrderStatus.New,
            timeProvider.GetUtcNow());
        await orders.SaveAsync(order, cancellationToken);
        return order;
    }

    public async Task<PizzaOrder?> UpdateStatusAsync(
        Guid id,
        OrderStatus status,
        CancellationToken cancellationToken)
    {
        if (!Enum.IsDefined(status))
        {
            throw new OrderValidationException("Order status is invalid.");
        }

        var order = await orders.GetAsync(id, cancellationToken);
        if (order is null)
        {
            return null;
        }

        if ((int)status != (int)order.Status + 1)
        {
            throw new OrderValidationException(
                $"Order status can only advance from {order.Status} to the next stage.");
        }

        var updated = order with { Status = status };
        await orders.SaveAsync(updated, cancellationToken);
        return updated;
    }
}

public sealed class OrderValidationException(string message) : Exception(message);
