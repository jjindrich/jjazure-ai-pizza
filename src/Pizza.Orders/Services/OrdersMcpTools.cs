using System.ComponentModel;
using ModelContextProtocol;
using ModelContextProtocol.Server;
using Pizza.Contracts;

namespace Pizza.Orders.Services;

[McpServerToolType]
public sealed class OrdersMcpTools(OrderService orders)
{
    [McpServerTool(Name = "list_new_orders", ReadOnly = true, Destructive = false)]
    [Description("List current pizza orders with status New. Read-only; does not change order state.")]
    public Task<IReadOnlyList<PizzaOrder>> ListNewOrders(CancellationToken cancellationToken) =>
        orders.GetAllAsync(OrderStatus.New, cancellationToken);

    [McpServerTool(Name = "get_order", ReadOnly = true, Destructive = false)]
    [Description("Get one pizza order by its full UUID, including customer delivery address and items. Read-only.")]
    public async Task<PizzaOrder> GetOrder(
        [Description("The full UUID of the pizza order.")] Guid orderId,
        CancellationToken cancellationToken)
    {
        return await orders.GetAsync(orderId, cancellationToken)
            ?? throw new McpException($"Order '{orderId}' was not found.");
    }
}
