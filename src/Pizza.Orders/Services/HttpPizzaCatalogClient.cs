using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Pizza.Contracts;

namespace Pizza.Orders.Services;

public sealed class HttpPizzaCatalogClient(
    IHttpClientFactory clients,
    ILogger<HttpPizzaCatalogClient> logger) : IPizzaCatalogReader
{
    public async Task<IReadOnlyList<PizzaItem>> GetAllAsync(CancellationToken cancellationToken) =>
        await ReadAsync<List<PizzaItem>>("api/catalog/pizzas", false, cancellationToken)
        ?? throw new CatalogUnavailableException("The catalog returned an empty payload.");

    public Task<PizzaItem?> GetAsync(Guid id, CancellationToken cancellationToken) =>
        ReadAsync<PizzaItem>($"api/catalog/pizzas/{id:D}", true, cancellationToken);

    private async Task<T?> ReadAsync<T>(string path, bool allowNotFound, CancellationToken cancellationToken)
        where T : class
    {
        try
        {
            using var client = clients.CreateClient("catalog");
            using var response = await client.GetAsync(path, cancellationToken);
            if (allowNotFound && response.StatusCode == HttpStatusCode.NotFound)
            {
                return null;
            }

            response.EnsureSuccessStatusCode();
            return await response.Content.ReadFromJsonAsync<T>(cancellationToken)
                ?? throw new JsonException("The catalog returned a null payload.");
        }
        catch (Exception exception) when (
            exception is HttpRequestException or JsonException ||
            exception is OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            logger.LogError(exception, "Catalog request {Path} failed.", path);
            throw new CatalogUnavailableException("The catalog is temporarily unavailable.", exception);
        }
    }
}

public sealed class CatalogUnavailableException(string message, Exception? inner = null)
    : Exception(message, inner);
