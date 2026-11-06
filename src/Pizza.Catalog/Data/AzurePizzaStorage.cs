using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Azure.Cosmos;
using Newtonsoft.Json;
using Pizza.Contracts;

namespace Pizza.Catalog.Data;

public static class AzurePizzaStorage
{
    public static void AddAzurePizzaStorage(this IServiceCollection services, IConfiguration configuration)
    {
        var endpoint = Required(configuration, "Pizza:Azure:CosmosEndpoint");
        var database = Required(configuration, "Pizza:Azure:CosmosDatabase");
        var container = Required(configuration, "Pizza:Azure:CosmosContainer");
        var storageAccountUrl = Required(configuration, "Pizza:Azure:StorageAccountUrl");
        var imageContainer = configuration["Pizza:Azure:ImagesContainer"] ?? "pizza-images";
        var credential = new DefaultAzureCredential();

        services.AddSingleton(new CosmosClient(endpoint, credential));
        services.AddSingleton<IPizzaCatalogStore>(provider => new CosmosPizzaCatalogStore(
            provider.GetRequiredService<CosmosClient>(), database, container));
        services.AddSingleton<IPizzaImageStore>(_ => new BlobPizzaImageStore(
            new BlobContainerClient(new Uri($"{storageAccountUrl.TrimEnd('/')}/{imageContainer}"), credential)));
    }

    private static string Required(IConfiguration configuration, string key) =>
        string.IsNullOrWhiteSpace(configuration[key])
            ? throw new InvalidOperationException($"Required configuration value '{key}' is missing.")
            : configuration[key]!;
}

public sealed class CosmosPizzaCatalogStore(
    CosmosClient client,
    string databaseName,
    string containerName) : IPizzaCatalogStore
{
    private Container Container => client.GetContainer(databaseName, containerName);

    public async Task<IReadOnlyList<PizzaItem>> GetAllAsync(CancellationToken cancellationToken)
    {
        using var iterator = Container.GetItemQueryIterator<PizzaDocument>(
            new QueryDefinition("SELECT * FROM c ORDER BY c.name"));
        var documents = new List<PizzaItem>();
        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            documents.AddRange(page.Select(document => document.ToPizzaItem()));
        }

        return documents;
    }

    public async Task<PizzaItem?> GetAsync(Guid id, CancellationToken cancellationToken)
    {
        try
        {
            var response = await Container.ReadItemAsync<PizzaDocument>(
                id.ToString("D"), new PartitionKey(id.ToString("D")), cancellationToken: cancellationToken);
            return response.Resource.ToPizzaItem();
        }
        catch (CosmosException exception) when (exception.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    public async Task SaveAsync(PizzaItem pizza, CancellationToken cancellationToken)
    {
        var document = PizzaDocument.FromPizzaItem(pizza);
        await Container.UpsertItemAsync(
            document, new PartitionKey(document.Id), cancellationToken: cancellationToken);
    }

    public async Task DeleteAsync(Guid id, CancellationToken cancellationToken)
    {
        try
        {
            await Container.DeleteItemAsync<PizzaDocument>(
                id.ToString("D"), new PartitionKey(id.ToString("D")), cancellationToken: cancellationToken);
        }
        catch (CosmosException exception) when (exception.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
        }
    }

    private sealed class PizzaDocument
    {
        [JsonProperty("id")]
        public string Id { get; init; } = "";

        [JsonProperty("name")]
        public string Name { get; init; } = "";

        [JsonProperty("description")]
        public string Description { get; init; } = "";

        [JsonProperty("price")]
        public decimal Price { get; init; }

        [JsonProperty("imageUrl")]
        public string ImageUrl { get; init; } = "";

        [JsonProperty("isAvailable")]
        public bool IsAvailable { get; init; }

        public static PizzaDocument FromPizzaItem(PizzaItem pizza) => new()
        {
            Id = pizza.Id.ToString("D"),
            Name = pizza.Name,
            Description = pizza.Description,
            Price = pizza.Price,
            ImageUrl = pizza.ImageUrl,
            IsAvailable = pizza.IsAvailable
        };

        public PizzaItem ToPizzaItem() =>
            new(Guid.Parse(Id), Name, Description, Price, ImageUrl, IsAvailable);
    }
}

public sealed class BlobPizzaImageStore(BlobContainerClient container) : IPizzaImageStore
{
    public async Task<string> SaveAsync(
        Stream image,
        string contentType,
        CancellationToken cancellationToken)
    {
        var key = $"{Guid.NewGuid():N}{ImageFilePolicy.GetExtension(contentType)}";
        var blob = container.GetBlobClient(key);
        await blob.UploadAsync(
            image,
            new BlobUploadOptions
            {
                HttpHeaders = new BlobHttpHeaders { ContentType = contentType }
            },
            cancellationToken);
        return key;
    }

    public async Task<ImageContent?> OpenReadAsync(string imageKey, CancellationToken cancellationToken)
    {
        if (Path.GetFileName(imageKey) != imageKey)
        {
            return null;
        }

        var blob = container.GetBlobClient(imageKey);
        try
        {
            var response = await blob.DownloadStreamingAsync(cancellationToken: cancellationToken);
            return new ImageContent(
                response.Value.Content,
                response.Value.Details.ContentType ?? ImageFilePolicy.GetContentType(Path.GetExtension(imageKey)));
        }
        catch (Azure.RequestFailedException exception) when (exception.Status == 404)
        {
            return null;
        }
    }
}
