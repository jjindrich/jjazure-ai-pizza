using System.Globalization;

namespace Pizza.Contracts;

public sealed class PriceDisplay
{
    public PriceDisplay(string? currencyCode)
    {
        CurrencyCode = string.IsNullOrWhiteSpace(currencyCode) ? null : currencyCode.Trim();
        if (CurrencyCode is not null &&
            (CurrencyCode.Length != 3 || CurrencyCode.Any(character => character is < 'A' or > 'Z')))
        {
            throw new ArgumentException("Pizza:CurrencyCode must be a three-letter uppercase ISO currency code.", nameof(currencyCode));
        }
    }

    public string? CurrencyCode { get; }
    public string Label => CurrencyCode is null ? "Price (currency not configured)" : $"Price ({CurrencyCode})";

    public string Format(decimal amount)
    {
        var number = amount.ToString("0.00", CultureInfo.InvariantCulture);
        return CurrencyCode is null ? number : $"{number} {CurrencyCode}";
    }
}
