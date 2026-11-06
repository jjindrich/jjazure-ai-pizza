using System.Net;
using System.Net.Sockets;
using Microsoft.Data.SqlClient;

using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(8));
var cancellationToken = timeout.Token;
var host = Required("SQL_HOST");
if (!host.EndsWith(".database.windows.net", StringComparison.OrdinalIgnoreCase) ||
    !Uri.CheckHostName(host).Equals(UriHostNameType.Dns))
{
    throw new InvalidOperationException("SQL_HOST must be an Azure SQL DNS hostname.");
}

var addresses = await Dns.GetHostAddressesAsync(host, cancellationToken);
if (addresses.Length == 0 || addresses.Any(address => !IsPrivateIpv4(address)))
{
    throw new InvalidOperationException("SQL DNS did not resolve exclusively to private IPv4 addresses.");
}

using (var tcp = new TcpClient())
{
    await tcp.ConnectAsync(host, 1433, cancellationToken);
}
Console.WriteLine("Private SQL DNS and TCP verified.");

var builder = new SqlConnectionStringBuilder
{
    DataSource = $"tcp:{host},1433",
    InitialCatalog = Required("SQL_DATABASE"),
    Authentication = SqlAuthenticationMethod.ActiveDirectoryManagedIdentity,
    UserID = Guid.Parse(Required("AZURE_CLIENT_ID")).ToString("D"),
    Encrypt = true,
    TrustServerCertificate = false,
    ConnectTimeout = 30,
    Pooling = false
};
await using var connection = new SqlConnection(builder.ConnectionString);

if (args.Contains("--verify-revoked", StringComparer.Ordinal))
{
    try
    {
        await connection.OpenAsync(cancellationToken);
    }
    catch (SqlException exception) when (exception.Number == 18456)
    {
        Console.WriteLine("Initializer SQL login denied after administrator handover.");
        return;
    }
    throw new InvalidOperationException("Initializer still connects after handover, or revocation could not be verified.");
}

await connection.OpenAsync(cancellationToken);
await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);
await using var command = connection.CreateCommand();
command.Transaction = transaction;
command.CommandTimeout = 60;
command.CommandText = await File.ReadAllTextAsync(
    Path.Combine(AppContext.BaseDirectory, "schema.sql"), cancellationToken);
await command.ExecuteNonQueryAsync(cancellationToken);

var clientId = Guid.Parse(Required("ORDERS_CLIENT_ID"));
var sid = $"0x{Convert.ToHexString(clientId.ToByteArray())}";
// Explicit application SID avoids tenant-wide Graph directory permissions.
command.CommandText = $"""
    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'pizza_orders' AND (sid <> {sid} OR type <> 'E'))
        THROW 51000, 'Existing Orders principal SID/type mismatch; refusing to replace it.', 1;
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'pizza_orders')
        CREATE USER [pizza_orders] WITH SID = {sid}, TYPE = E;
    GRANT CONNECT TO [pizza_orders];
    GRANT SELECT, INSERT, UPDATE ON OBJECT::dbo.PizzaOrders TO [pizza_orders];
    IF EXISTS (SELECT 1 FROM sys.database_role_members rm
        JOIN sys.database_principals p ON p.principal_id = rm.member_principal_id
        WHERE p.name = N'pizza_orders')
        THROW 51001, 'Orders principal unexpectedly belongs to a database role.', 1;
    IF EXISTS (SELECT 1 FROM sys.database_permissions dp
        JOIN sys.database_principals p ON p.principal_id = dp.grantee_principal_id
        WHERE p.name = N'pizza_orders' AND NOT
          (dp.state = 'G' AND dp.minor_id = 0 AND
           ((dp.class = 0 AND dp.permission_name = 'CONNECT') OR
            (dp.class = 1 AND dp.major_id = OBJECT_ID(N'dbo.PizzaOrders') AND
             dp.permission_name IN ('SELECT', 'INSERT', 'UPDATE')))))
        THROW 51002, 'Orders principal has unexpected explicit permissions.', 1;
    """;
await command.ExecuteNonQueryAsync(cancellationToken);
command.CommandText = """
    SELECT COUNT(*) FROM sys.database_permissions dp
    JOIN sys.database_principals p ON p.principal_id = dp.grantee_principal_id
    WHERE p.name = N'pizza_orders' AND dp.state = 'G' AND
      ((dp.class = 0 AND dp.permission_name = 'CONNECT') OR
       (dp.class = 1 AND dp.major_id = OBJECT_ID(N'dbo.PizzaOrders') AND
        dp.permission_name IN ('SELECT', 'INSERT', 'UPDATE')));
    """;
if (Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken)) != 4)
{
    throw new InvalidOperationException("Expected Orders permissions were not verified.");
}
await transaction.CommitAsync(cancellationToken);
Console.WriteLine("Schema, Orders application SID and exactly four grants verified; initialization committed.");

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
        ? value
        : throw new InvalidOperationException($"{name} is required.");

static bool IsPrivateIpv4(IPAddress address)
{
    if (address.AddressFamily != AddressFamily.InterNetwork)
    {
        return false;
    }
    var bytes = address.GetAddressBytes();
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
}
