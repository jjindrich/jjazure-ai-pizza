using Pizza.Contracts;

namespace Pizza.Contracts.Tests;

public sealed class ServiceLinksTests
{
    [Fact]
    public void ConfiguredOrigins_ProduceCrossServiceRoutes()
    {
        var links = new ServiceLinks("https://pizza.example/", false);
        Assert.Equal("https://pizza.example/", links.Menu);
        Assert.Equal("https://pizza.example/orders", links.Orders);
    }

    [Fact]
    public void MissingOrigin_PreservesExistingRelativeNavigation()
    {
        var links = new ServiceLinks(null, false);
        Assert.Equal("", links.Menu);
        Assert.Equal("orders", links.Orders);
    }

    [Theory]
    [InlineData("http://pizza.example")]
    [InlineData("https://pizza.example/orders")]
    [InlineData("https://pizza.example/?target=x")]
    [InlineData("https://user:password@pizza.example")]
    [InlineData("javascript:alert(1)")]
    public void InvalidOrigin_IsRejected(string origin) =>
        Assert.Throws<ArgumentException>(() => new ServiceLinks(origin, false));

    [Fact]
    public void LoopbackHttp_IsAllowedOnlyInDevelopment()
    {
        Assert.Equal("http://127.0.0.1:5189/orders", new ServiceLinks("http://127.0.0.1:5189", true).Orders);
        Assert.Throws<ArgumentException>(() => new ServiceLinks("http://127.0.0.1:5189", false));
    }
}
