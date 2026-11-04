namespace Pizza.Contracts;

public sealed record PizzaItem(
    Guid Id,
    string Name,
    string Description,
    decimal Price,
    string ImageUrl,
    bool IsAvailable = true);

public enum OrderStatus
{
    New,
    Preparing,
    OutForDelivery,
    Completed
}

public sealed record Customer(string Name, string Address);

public sealed record OrderLine(Guid PizzaId, string PizzaName, decimal UnitPrice, int Quantity)
{
    public decimal LineTotal => UnitPrice * Quantity;
}

public sealed record PizzaOrder(
    Guid Id,
    Customer Customer,
    IReadOnlyList<OrderLine> Items,
    OrderStatus Status,
    DateTimeOffset CreatedAt)
{
    public decimal Total => Items.Sum(item => item.LineTotal);
}

public sealed record PizzaUpsertRequest(
    string Name,
    string Description,
    decimal Price,
    bool IsAvailable = true);

public sealed record OrderItemRequest(Guid PizzaId, int Quantity);

public sealed record CreateOrderRequest(
    string CustomerName,
    string CustomerAddress,
    IReadOnlyList<OrderItemRequest> Items);

public sealed record UpdateOrderStatusRequest(OrderStatus Status);

public sealed record ImageContent(Stream Stream, string ContentType);
