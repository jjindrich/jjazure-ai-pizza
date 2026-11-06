using Microsoft.Data.SqlClient;
using Newtonsoft.Json;
using Pizza.Contracts;

namespace Pizza.Orders.Data;

public sealed class SqlOrderStore(string connectionString) : IOrderStore
{
    private static readonly JsonSerializerSettings JsonSettings = new()
    {
        TypeNameHandling = TypeNameHandling.None
    };

    public async Task<IReadOnlyList<PizzaOrder>> GetAllAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT Id, CustomerName, CustomerAddress, ItemsJson, Status, CreatedAt
            FROM dbo.PizzaOrders
            ORDER BY CreatedAt DESC;
            """;
        var orders = new List<PizzaOrder>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            orders.Add(ReadOrder(reader));
        }

        return orders;
    }

    public async Task<PizzaOrder?> GetAsync(Guid id, CancellationToken cancellationToken)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT Id, CustomerName, CustomerAddress, ItemsJson, Status, CreatedAt
            FROM dbo.PizzaOrders WHERE Id = @id;
            """;
        command.Parameters.AddWithValue("@id", id);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? ReadOrder(reader) : null;
    }

    public async Task SaveAsync(PizzaOrder order, CancellationToken cancellationToken)
    {
        var itemsJson = JsonConvert.SerializeObject(order.Items, JsonSettings);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            UPDATE dbo.PizzaOrders
            SET CustomerName = @customerName, CustomerAddress = @customerAddress,
                ItemsJson = @itemsJson, Status = @status
            WHERE Id = @id;
            IF @@ROWCOUNT = 0
                INSERT dbo.PizzaOrders (Id, CustomerName, CustomerAddress, ItemsJson, Status, CreatedAt)
                VALUES (@id, @customerName, @customerAddress, @itemsJson, @status, @createdAt);
            """;
        command.Parameters.AddWithValue("@id", order.Id);
        command.Parameters.AddWithValue("@customerName", order.Customer.Name);
        command.Parameters.AddWithValue("@customerAddress", order.Customer.Address);
        command.Parameters.Add("@itemsJson", System.Data.SqlDbType.NVarChar, -1).Value = itemsJson;
        command.Parameters.AddWithValue("@status", (int)order.Status);
        command.Parameters.AddWithValue("@createdAt", order.CreatedAt);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private async Task<SqlConnection> OpenConnectionAsync(CancellationToken cancellationToken)
    {
        var builder = new SqlConnectionStringBuilder(connectionString)
        {
            Encrypt = true,
            TrustServerCertificate = false
        };
        if (builder.Authentication == SqlAuthenticationMethod.NotSpecified)
        {
            builder.Authentication = SqlAuthenticationMethod.ActiveDirectoryDefault;
        }

        var connection = new SqlConnection(builder.ConnectionString);
        try
        {
            await connection.OpenAsync(cancellationToken);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private static PizzaOrder ReadOrder(SqlDataReader reader)
    {
        var items = JsonConvert.DeserializeObject<List<OrderLine>>(
            reader.GetString(3), JsonSettings) ?? [];
        return new PizzaOrder(
            reader.GetGuid(0),
            new Customer(reader.GetString(1), reader.GetString(2)),
            items,
            (OrderStatus)reader.GetInt32(4),
            reader.GetDateTimeOffset(5));
    }
}
