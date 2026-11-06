using Pizza.Orders.Data;
using Pizza.Catalog.Data;
using Pizza.Contracts;
using Pizza.Orders.Services;

namespace Pizza.Orders.Tests;

public sealed class OrderServiceTests
{
    [Fact]
    public async Task CreateAsync_SnapshotsCatalogPriceAndCreatesNewOrder()
    {
        var catalog = new InMemoryPizzaCatalogStore();
        var store = new InMemoryOrderStore();
        var pizza = new PizzaItem(Guid.NewGuid(), "Margherita", "Tomato and mozzarella", 12.50m, "/pizza.svg");
        await catalog.SaveAsync(pizza, CancellationToken.None);
        var service = new OrderService(store, catalog, TimeProvider.System);

        var order = await service.CreateAsync(
            new CreateOrderRequest("Ada", "1 Main Street", [new OrderItemRequest(pizza.Id, 2)]),
            CancellationToken.None);

        Assert.Equal(OrderStatus.New, order.Status);
        Assert.Equal(25.00m, order.Total);
        Assert.Equal(12.50m, order.Items.Single().UnitPrice);

        await catalog.SaveAsync(pizza with { Price = 20m }, CancellationToken.None);
        Assert.Equal(25.00m, (await service.GetAsync(order.Id, CancellationToken.None))!.Total);
    }

    [Fact]
    public async Task CreateAsync_RejectsUnavailablePizza()
    {
        var catalog = new InMemoryPizzaCatalogStore();
        var pizza = new PizzaItem(Guid.NewGuid(), "Sold out", "Not available", 9m, "/pizza.svg", false);
        await catalog.SaveAsync(pizza, CancellationToken.None);
        var service = new OrderService(new InMemoryOrderStore(), catalog, TimeProvider.System);

        var exception = await Assert.ThrowsAsync<OrderValidationException>(() => service.CreateAsync(
            new CreateOrderRequest("Ada", "1 Main Street", [new OrderItemRequest(pizza.Id, 1)]),
            CancellationToken.None));

        Assert.Contains("unavailable", exception.Message);
    }

    [Fact]
    public async Task UpdateStatusAsync_OnlyAllowsNextWorkflowStage()
    {
        var catalog = new InMemoryPizzaCatalogStore();
        var pizza = new PizzaItem(Guid.NewGuid(), "Margherita", "Tomato and mozzarella", 12m, "/pizza.svg");
        await catalog.SaveAsync(pizza, CancellationToken.None);
        var service = new OrderService(new InMemoryOrderStore(), catalog, TimeProvider.System);
        var order = await service.CreateAsync(
            new CreateOrderRequest("Ada", "1 Main Street", [new OrderItemRequest(pizza.Id, 1)]),
            CancellationToken.None);

        await Assert.ThrowsAsync<OrderValidationException>(() =>
            service.UpdateStatusAsync(order.Id, OrderStatus.OutForDelivery, CancellationToken.None));
        var updated = await service.UpdateStatusAsync(order.Id, OrderStatus.Preparing, CancellationToken.None);

        Assert.Equal(OrderStatus.Preparing, updated!.Status);
    }

    [Fact]
    public async Task CreateAsync_RejectsInvalidQuantity()
    {
        var catalog = new InMemoryPizzaCatalogStore();
        var pizza = new PizzaItem(Guid.NewGuid(), "Margherita", "Tomato and mozzarella", 12m, "/pizza.svg");
        await catalog.SaveAsync(pizza, CancellationToken.None);
        var service = new OrderService(new InMemoryOrderStore(), catalog, TimeProvider.System);

        await Assert.ThrowsAsync<OrderValidationException>(() => service.CreateAsync(
            new CreateOrderRequest("Ada", "1 Main Street", [new OrderItemRequest(pizza.Id, 0)]),
            CancellationToken.None));
    }
}
