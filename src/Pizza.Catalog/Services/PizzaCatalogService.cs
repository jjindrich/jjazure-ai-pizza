using Pizza.Contracts;

namespace Pizza.Catalog.Services;

public sealed class PizzaCatalogService(IPizzaCatalogStore store)
{
    public Task<IReadOnlyList<PizzaItem>> GetAllAsync(CancellationToken cancellationToken) =>
        store.GetAllAsync(cancellationToken);

    public Task<PizzaItem?> GetAsync(Guid id, CancellationToken cancellationToken) =>
        store.GetAsync(id, cancellationToken);

    public async Task<PizzaItem> CreateAsync(
        PizzaUpsertRequest request,
        CancellationToken cancellationToken)
    {
        Validate(request);
        var pizza = new PizzaItem(
            Guid.NewGuid(),
            request.Name.Trim(),
            request.Description.Trim(),
            request.Price,
            "/images/pizza.svg",
            request.IsAvailable);
        await store.SaveAsync(pizza, cancellationToken);
        return pizza;
    }

    public async Task<PizzaItem?> UpdateAsync(
        Guid id,
        PizzaUpsertRequest request,
        CancellationToken cancellationToken)
    {
        Validate(request);
        var current = await store.GetAsync(id, cancellationToken);
        if (current is null)
        {
            return null;
        }

        var updated = current with
        {
            Name = request.Name.Trim(),
            Description = request.Description.Trim(),
            Price = request.Price,
            IsAvailable = request.IsAvailable
        };
        await store.SaveAsync(updated, cancellationToken);
        return updated;
    }

    public async Task<PizzaItem?> SetImageAsync(
        Guid id,
        string imageUrl,
        CancellationToken cancellationToken)
    {
        var current = await store.GetAsync(id, cancellationToken);
        if (current is null)
        {
            return null;
        }

        var updated = current with { ImageUrl = imageUrl };
        await store.SaveAsync(updated, cancellationToken);
        return updated;
    }

    public async Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken)
    {
        if (await store.GetAsync(id, cancellationToken) is null)
        {
            return false;
        }

        await store.DeleteAsync(id, cancellationToken);
        return true;
    }

    public static void Validate(PizzaUpsertRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name) || request.Name.Trim().Length > 100)
        {
            throw new CatalogValidationException("Name is required and must be 100 characters or fewer.");
        }

        if (string.IsNullOrWhiteSpace(request.Description) || request.Description.Trim().Length > 500)
        {
            throw new CatalogValidationException("Description is required and must be 500 characters or fewer.");
        }

        if (request.Price is <= 0 or > 10000)
        {
            throw new CatalogValidationException("Price must be greater than 0 and no more than 10,000.");
        }
    }
}

public sealed class CatalogValidationException(string message) : Exception(message);

public sealed class CatalogSeedService(
    IServiceProvider services,
    ILogger<CatalogSeedService> logger) : IHostedService
{
    private static readonly (string Name, string Description, decimal Price, string ImageUrl)[] Menu =
    [
        ("Margherita", "Tomato sauce, mozzarella, fresh basil", 10.50m, "/images/menu/margherita.svg"),
        ("Pepperoni", "Tomato sauce, mozzarella, pepperoni", 12.90m, "/images/menu/pepperoni.svg"),
        ("Quattro Formaggi", "Mozzarella, gorgonzola, parmesan, fontina", 13.50m, "/images/menu/quattro-formaggi.svg"),
        ("Prosciutto e Rucola", "Tomato sauce, mozzarella, prosciutto, rocket", 14.20m, "/images/menu/prosciutto-rucola.svg"),
        ("Funghi", "Cream sauce, mozzarella, roasted mushrooms, thyme", 12.40m, "/images/menu/funghi.svg"),
        ("Diavola", "Tomato sauce, mozzarella, spicy salami, chili", 13.20m, "/images/menu/diavola.svg"),
        ("Vegetariana", "Tomato sauce, mozzarella, peppers, courgette, olives", 12.60m, "/images/menu/vegetariana.svg"),
        ("Hawaiian", "Tomato sauce, mozzarella, ham, pineapple", 12.80m, "/images/menu/hawaiian.svg"),
        ("Capricciosa", "Tomato sauce, mozzarella, ham, mushrooms, artichokes", 13.80m, "/images/menu/capricciosa.svg"),
        ("Salsiccia", "Tomato sauce, mozzarella, Italian sausage, red onion", 14.00m, "/images/menu/salsiccia.svg")
    ];

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        using var scope = services.CreateScope();
        var store = scope.ServiceProvider.GetRequiredService<IPizzaCatalogStore>();
        var existing = await store.GetAllAsync(cancellationToken);
        if (existing.Count > 0)
        {
            return;
        }

        for (var index = 0; index < Menu.Length; index++)
        {
            var item = Menu[index];
            await store.SaveAsync(
                new PizzaItem(
                    Guid.Parse($"00000000-0000-0000-0000-{index + 1:000000000000}"),
                    item.Name,
                    item.Description,
                    item.Price,
                    item.ImageUrl),
                cancellationToken);
        }

        logger.LogInformation("Seeded {Count} pizza catalog items.", Menu.Length);
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
