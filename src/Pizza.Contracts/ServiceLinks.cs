namespace Pizza.Contracts;

public sealed class ServiceLinks
{
    public ServiceLinks(string? origin, bool allowLoopbackHttp)
    {
        if (string.IsNullOrWhiteSpace(origin))
        {
            return;
        }

        if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttps && !(allowLoopbackHttp && uri.IsLoopback && uri.Scheme == Uri.UriSchemeHttp)) ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment) || uri.AbsolutePath != "/")
        {
            throw new ArgumentException("The other service URL must be an HTTPS origin (loopback HTTP is allowed in Development).", nameof(origin));
        }

        Origin = uri.GetLeftPart(UriPartial.Authority);
    }

    public string? Origin { get; }
    public string Menu => Origin is null ? "" : $"{Origin}/";
    public string Orders => Origin is null ? "orders" : $"{Origin}/orders";
}
