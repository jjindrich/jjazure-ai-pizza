using System.Globalization;
using Pizza.Contracts;

namespace Pizza.Contracts.Tests;

public sealed class PriceDisplayTests
{
    [Theory]
    [InlineData("en-US")]
    [InlineData("cs-CZ")]
    [InlineData("")]
    public void Format_IsIndependentOfHostCultureAndNeverInventsCurrency(string culture)
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(culture);
            Assert.Equal("10.50", new PriceDisplay(null).Format(10.5m));
            Assert.Equal("10.50 CZK", new PriceDisplay("CZK").Format(10.5m));
            Assert.Equal("21.00 EUR", new PriceDisplay("EUR").Format(21));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(" ")]
    public void MissingCurrency_IsExplicitlyUnconfigured(string? code)
    {
        var display = new PriceDisplay(code);
        Assert.Null(display.CurrencyCode);
        Assert.Contains("currency not configured", display.Label);
    }

    [Theory]
    [InlineData("$")]
    [InlineData("eur")]
    [InlineData("EURO")]
    [InlineData("12X")]
    public void InvalidConfiguration_FailsRatherThanSilentlySelectingCurrency(string code) =>
        Assert.Throws<ArgumentException>(() => new PriceDisplay(code));
}
