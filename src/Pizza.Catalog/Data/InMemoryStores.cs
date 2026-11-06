using System.Collections.Concurrent;
using Pizza.Contracts;

namespace Pizza.Catalog.Data;

public sealed class InMemoryPizzaCatalogStore : IPizzaCatalogStore
{
    private readonly ConcurrentDictionary<Guid, PizzaItem> _pizzas = new();

    public Task<IReadOnlyList<PizzaItem>> GetAllAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<PizzaItem>>(
            _pizzas.Values.OrderBy(pizza => pizza.Name).ToArray());

    public Task<PizzaItem?> GetAsync(Guid id, CancellationToken cancellationToken) =>
        Task.FromResult(_pizzas.GetValueOrDefault(id));

    public Task SaveAsync(PizzaItem pizza, CancellationToken cancellationToken)
    {
        _pizzas[pizza.Id] = pizza;
        return Task.CompletedTask;
    }

    public Task DeleteAsync(Guid id, CancellationToken cancellationToken)
    {
        _pizzas.TryRemove(id, out _);
        return Task.CompletedTask;
    }
}

public sealed class LocalPizzaImageStore : IPizzaImageStore
{
    private const int MaxImageBytes = 5 * 1024 * 1024;
    private readonly string _directory;

    public LocalPizzaImageStore(IWebHostEnvironment environment)
    {
        _directory = Path.Combine(environment.ContentRootPath, "App_Data", "images");
    }

    public async Task<string> SaveAsync(
        Stream image,
        string contentType,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(_directory);
        var extension = ImageFilePolicy.GetExtension(contentType);
        var key = $"{Guid.NewGuid():N}{extension}";
        await using var target = new FileStream(
            Path.Combine(_directory, key), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        await CopyLimitedAsync(image, target, cancellationToken);
        return key;
    }

    public async Task<ImageContent?> OpenReadAsync(string imageKey, CancellationToken cancellationToken)
    {
        if (Path.GetFileName(imageKey) != imageKey)
        {
            return null;
        }

        var path = Path.Combine(_directory, imageKey);
        if (!File.Exists(path))
        {
            return null;
        }

        var contentType = ImageFilePolicy.GetContentType(Path.GetExtension(path));
        return new ImageContent(
            new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read),
            contentType);
    }

    internal static async Task CopyLimitedAsync(
        Stream source,
        Stream destination,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[81920];
        var total = 0;
        int read;
        while ((read = await source.ReadAsync(buffer, cancellationToken)) > 0)
        {
            total += read;
            if (total > MaxImageBytes)
            {
                throw new InvalidDataException("Images must be 5 MB or smaller.");
            }

            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
        }

        if (total == 0)
        {
            throw new InvalidDataException("The uploaded image is empty.");
        }
    }
}

public static class ImageFilePolicy
{
    public static async Task<byte[]> ReadValidatedAsync(
        Stream source,
        string contentType,
        CancellationToken cancellationToken)
    {
        _ = GetExtension(contentType);
        await using var buffer = new MemoryStream();
        await LocalPizzaImageStore.CopyLimitedAsync(source, buffer, cancellationToken);
        var bytes = buffer.ToArray();
        var valid = contentType.ToLowerInvariant() switch
        {
            "image/jpeg" => bytes.Length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff,
            "image/png" => bytes.AsSpan().StartsWith(
                new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a }),
            "image/webp" => bytes.Length >= 12 &&
                bytes.AsSpan(0, 4).SequenceEqual("RIFF"u8) &&
                bytes.AsSpan(8, 4).SequenceEqual("WEBP"u8),
            _ => false
        };
        if (!valid)
        {
            throw new InvalidDataException("The image content does not match its JPEG, PNG, or WebP type.");
        }

        return bytes;
    }

    public static string GetExtension(string contentType) => contentType.ToLowerInvariant() switch
    {
        "image/jpeg" => ".jpg",
        "image/png" => ".png",
        "image/webp" => ".webp",
        _ => throw new InvalidDataException("Only JPEG, PNG, and WebP images are supported.")
    };

    public static string GetContentType(string extension) => extension.ToLowerInvariant() switch
    {
        ".jpg" or ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".webp" => "image/webp",
        _ => "application/octet-stream"
    };
}
