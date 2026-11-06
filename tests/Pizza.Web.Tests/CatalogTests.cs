using System.ComponentModel.DataAnnotations;
using Pizza.Catalog.Data;
using Pizza.Catalog.Services;
using Pizza.Contracts;

namespace Pizza.Catalog.Tests;

public sealed class CatalogTests
{
    [Fact]
    public async Task CreateAsync_PersistsTrimmedPizzaWithDefaultImageAndAvailability()
    {
        var service = new PizzaCatalogService(new InMemoryPizzaCatalogStore());
        var pizza = await service.CreateAsync(
            new PizzaUpsertRequest("  New pizza  ", "  Tomato and basil  ", 12.50m, false),
            CancellationToken.None);

        Assert.NotEqual(Guid.Empty, pizza.Id);
        Assert.Equal("New pizza", pizza.Name);
        Assert.Equal("Tomato and basil", pizza.Description);
        Assert.Equal(12.50m, pizza.Price);
        Assert.False(pizza.IsAvailable);
        Assert.Equal("/images/pizza.svg", pizza.ImageUrl);
        Assert.Equal(pizza, await service.GetAsync(pizza.Id, CancellationToken.None));
    }

    [Theory]
    [InlineData("", "Description", 10)]
    [InlineData("  ", "Description", 10)]
    [InlineData("Name", "", 10)]
    [InlineData("Name", "  ", 10)]
    [InlineData("Name", "Description", 0)]
    [InlineData("Name", "Description", -1)]
    [InlineData("Name", "Description", 10000.01)]
    public async Task FormAndService_RejectTheSameInvalidRequests(string name, string description, double price)
    {
        var model = new PizzaFormModel { Name = name, Description = description, Price = (decimal)price };
        var errors = new List<ValidationResult>();
        Assert.False(Validator.TryValidateObject(model, new ValidationContext(model), errors, true));

        var service = new PizzaCatalogService(new InMemoryPizzaCatalogStore());
        var exception = await Assert.ThrowsAsync<CatalogValidationException>(() =>
            service.CreateAsync(model.ToRequest(), CancellationToken.None));
        Assert.Equal(exception.Message, Assert.Single(errors).ErrorMessage);
        Assert.Empty(await service.GetAllAsync(CancellationToken.None));
    }

    [Theory]
    [InlineData(101, 10)]
    [InlineData(10, 501)]
    public void Validate_RejectsOverlongFields(int nameLength, int descriptionLength)
    {
        Assert.Throws<CatalogValidationException>(() => PizzaCatalogService.Validate(
            new PizzaUpsertRequest(new string('n', nameLength), new string('d', descriptionLength), 10)));
    }

    [Fact]
    public void Form_AcceptsServiceBoundariesAndCreatesAvailablePizzaByDefault()
    {
        var model = new PizzaFormModel
        {
            Name = new string('n', 100),
            Description = new string('d', 500),
            Price = 10000
        };
        Assert.True(Validator.TryValidateObject(model, new ValidationContext(model), [], true));
        Assert.True(model.ToRequest().IsAvailable);
        PizzaCatalogService.Validate(model.ToRequest() with { Price = 0.001m });
    }

    [Fact]
    public async Task UpdateAsync_PreservesIdentityAndImageAndDoesNotCreateMissingItems()
    {
        var service = new PizzaCatalogService(new InMemoryPizzaCatalogStore());
        var pizza = await service.CreateAsync(new PizzaUpsertRequest("Name", "Description", 10), CancellationToken.None);
        await service.SetImageAsync(pizza.Id, "/api/catalog/images/photo.png", CancellationToken.None);
        var request = new PizzaUpsertRequest(" Updated ", " New description ", 20, false);

        var updated = await service.UpdateAsync(pizza.Id, request, CancellationToken.None);

        Assert.NotNull(updated);
        Assert.Equal(pizza.Id, updated.Id);
        Assert.Equal("/api/catalog/images/photo.png", updated.ImageUrl);
        Assert.Equal("Updated", updated.Name);
        Assert.Equal(20, updated.Price);
        Assert.False(updated.IsAvailable);
        Assert.Null(await service.UpdateAsync(Guid.NewGuid(), request, CancellationToken.None));
        Assert.Single(await service.GetAllAsync(CancellationToken.None));
    }
}
