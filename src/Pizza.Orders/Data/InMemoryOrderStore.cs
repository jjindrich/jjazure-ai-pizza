using System.Collections.Concurrent;
using Pizza.Contracts;

namespace Pizza.Orders.Data;

public sealed class InMemoryOrderStore : IOrderStore
{
    private readonly ConcurrentDictionary<Guid, PizzaOrder> _orders = new();

    public Task<IReadOnlyList<PizzaOrder>> GetAllAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<PizzaOrder>>(
            _orders.Values.OrderByDescending(order => order.CreatedAt).ToArray());

    public Task<PizzaOrder?> GetAsync(Guid id, CancellationToken cancellationToken) =>
        Task.FromResult(_orders.GetValueOrDefault(id));

    public Task SaveAsync(PizzaOrder order, CancellationToken cancellationToken)
    {
        _orders[order.Id] = order;
        return Task.CompletedTask;
    }
}
