using Pizza.Catalog.Data;

namespace Pizza.Orders.Tests;

public sealed class ImageFilePolicyTests
{
    [Fact]
    public async Task ReadValidatedAsync_RejectsContentThatDoesNotMatchImageType()
    {
        await using var stream = new MemoryStream("not an image"u8.ToArray());

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            ImageFilePolicy.ReadValidatedAsync(stream, "image/png", CancellationToken.None));
    }

    [Fact]
    public async Task ReadValidatedAsync_RejectsUnsupportedTypes()
    {
        await using var stream = new MemoryStream([1, 2, 3]);

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            ImageFilePolicy.ReadValidatedAsync(stream, "image/svg+xml", CancellationToken.None));
    }
}
