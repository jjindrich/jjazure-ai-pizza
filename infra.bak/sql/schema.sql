IF OBJECT_ID(N'dbo.PizzaOrders', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PizzaOrders
    (
        Id uniqueidentifier NOT NULL CONSTRAINT PK_PizzaOrders PRIMARY KEY,
        CustomerName nvarchar(120) NOT NULL,
        CustomerAddress nvarchar(500) NOT NULL,
        ItemsJson nvarchar(max) NOT NULL,
        Status int NOT NULL,
        CreatedAt datetimeoffset(7) NOT NULL,
        CONSTRAINT CK_PizzaOrders_Status CHECK (Status BETWEEN 0 AND 3),
        CONSTRAINT CK_PizzaOrders_ItemsJson CHECK (ISJSON(ItemsJson) = 1)
    );
END;
GO
