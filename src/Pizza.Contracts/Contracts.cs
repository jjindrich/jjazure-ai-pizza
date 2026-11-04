namespace Pizza.Contracts;

public interface IPizzaCatalogReader
{
    Task<IReadOnlyList<PizzaItem>> GetAllAsync(CancellationToken cancellationToken);
    Task<PizzaItem?> GetAsync(Guid id, CancellationToken cancellationToken);
}

public interface IPizzaCatalogStore : IPizzaCatalogReader
{
    Task SaveAsync(PizzaItem pizza, CancellationToken cancellationToken);
    Task DeleteAsync(Guid id, CancellationToken cancellationToken);
}

public interface IOrderStore
{
    Task<IReadOnlyList<PizzaOrder>> GetAllAsync(CancellationToken cancellationToken);
    Task<PizzaOrder?> GetAsync(Guid id, CancellationToken cancellationToken);
    Task SaveAsync(PizzaOrder order, CancellationToken cancellationToken);
}

public interface IPizzaImageStore
{
    Task<string> SaveAsync(Stream image, string contentType, CancellationToken cancellationToken);
    Task<ImageContent?> OpenReadAsync(string imageKey, CancellationToken cancellationToken);
}
