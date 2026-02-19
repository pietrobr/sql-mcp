-- ============================================
-- SQL MCP Server Test Database
-- Database: OrdersDB
-- Schema: Categories, Products, Customers, Orders, OrderItems
-- ============================================

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'OrdersDB')
BEGIN
    CREATE DATABASE OrdersDB;
END
GO

USE OrdersDB;
GO

-- ============================================
-- Tables
-- ============================================

-- Categories
IF OBJECT_ID('dbo.OrderItems', 'U') IS NOT NULL DROP TABLE dbo.OrderItems;
IF OBJECT_ID('dbo.Orders', 'U') IS NOT NULL DROP TABLE dbo.Orders;
IF OBJECT_ID('dbo.Products', 'U') IS NOT NULL DROP TABLE dbo.Products;
IF OBJECT_ID('dbo.Customers', 'U') IS NOT NULL DROP TABLE dbo.Customers;
IF OBJECT_ID('dbo.Categories', 'U') IS NOT NULL DROP TABLE dbo.Categories;
GO

CREATE TABLE dbo.Categories (
    id          INT           NOT NULL PRIMARY KEY IDENTITY(1,1),
    name        NVARCHAR(100) NOT NULL,
    description NVARCHAR(500) NULL
);
GO

CREATE TABLE dbo.Products (
    id          INT             NOT NULL PRIMARY KEY IDENTITY(1,1),
    name        NVARCHAR(200)   NOT NULL,
    price       DECIMAL(10, 2)  NOT NULL,
    category_id INT             NOT NULL,
    CONSTRAINT FK_Products_Categories FOREIGN KEY (category_id) REFERENCES dbo.Categories(id)
);
GO

CREATE TABLE dbo.Customers (
    id         INT           NOT NULL PRIMARY KEY IDENTITY(1,1),
    first_name NVARCHAR(100) NOT NULL,
    last_name  NVARCHAR(100) NOT NULL,
    email      NVARCHAR(200) NOT NULL
);
GO

CREATE TABLE dbo.Orders (
    id           INT            NOT NULL PRIMARY KEY IDENTITY(1,1),
    customer_id  INT            NOT NULL,
    order_date   DATETIME2      NOT NULL DEFAULT GETUTCDATE(),
    total_amount DECIMAL(10, 2) NOT NULL DEFAULT 0,
    status       NVARCHAR(50)   NOT NULL DEFAULT 'Pending',
    CONSTRAINT FK_Orders_Customers FOREIGN KEY (customer_id) REFERENCES dbo.Customers(id)
);
GO

CREATE TABLE dbo.OrderItems (
    id         INT            NOT NULL PRIMARY KEY IDENTITY(1,1),
    order_id   INT            NOT NULL,
    product_id INT            NOT NULL,
    quantity   INT            NOT NULL,
    unit_price DECIMAL(10, 2) NOT NULL,
    CONSTRAINT FK_OrderItems_Orders   FOREIGN KEY (order_id)   REFERENCES dbo.Orders(id),
    CONSTRAINT FK_OrderItems_Products FOREIGN KEY (product_id) REFERENCES dbo.Products(id)
);
GO

-- ============================================
-- Seed Data
-- ============================================

-- Categories (3)
SET IDENTITY_INSERT dbo.Categories ON;
INSERT INTO dbo.Categories (id, name, description) VALUES
    (1, N'Electronics',  N'Electronic devices and accessories'),
    (2, N'Books',        N'Physical and digital books'),
    (3, N'Clothing',     N'Apparel and fashion items');
SET IDENTITY_INSERT dbo.Categories OFF;
GO

-- Products (10)
SET IDENTITY_INSERT dbo.Products ON;
INSERT INTO dbo.Products (id, name, price, category_id) VALUES
    (1,  N'Wireless Mouse',        29.99,  1),
    (2,  N'Mechanical Keyboard',  149.99,  1),
    (3,  N'USB-C Hub',             49.99,  1),
    (4,  N'27" Monitor',          399.99,  1),
    (5,  N'Clean Code',            39.99,  2),
    (6,  N'Design Patterns',       44.99,  2),
    (7,  N'The Pragmatic Programmer', 42.99, 2),
    (8,  N'Cotton T-Shirt',        19.99,  3),
    (9,  N'Denim Jeans',           59.99,  3),
    (10, N'Running Shoes',         89.99,  3);
SET IDENTITY_INSERT dbo.Products OFF;
GO

-- Customers (5)
SET IDENTITY_INSERT dbo.Customers ON;
INSERT INTO dbo.Customers (id, first_name, last_name, email) VALUES
    (1, N'Alice',   N'Johnson',  N'alice.johnson@example.com'),
    (2, N'Bob',     N'Smith',    N'bob.smith@example.com'),
    (3, N'Charlie', N'Brown',    N'charlie.brown@example.com'),
    (4, N'Diana',   N'Martinez', N'diana.martinez@example.com'),
    (5, N'Edward',  N'Lee',      N'edward.lee@example.com');
SET IDENTITY_INSERT dbo.Customers OFF;
GO

-- Orders (8)
SET IDENTITY_INSERT dbo.Orders ON;
INSERT INTO dbo.Orders (id, customer_id, order_date, total_amount, status) VALUES
    (1, 1, '2025-01-15 10:30:00', 229.97, N'Completed'),
    (2, 2, '2025-01-20 14:15:00',  84.98, N'Completed'),
    (3, 1, '2025-02-01 09:00:00',  49.99, N'Shipped'),
    (4, 3, '2025-02-10 16:45:00', 489.98, N'Completed'),
    (5, 4, '2025-02-15 11:20:00',  59.99, N'Processing'),
    (6, 5, '2025-02-18 08:30:00', 179.98, N'Pending'),
    (7, 2, '2025-03-01 13:00:00',  39.99, N'Completed'),
    (8, 3, '2025-03-05 17:30:00', 149.98, N'Shipped');
SET IDENTITY_INSERT dbo.Orders OFF;
GO

-- OrderItems (20)
SET IDENTITY_INSERT dbo.OrderItems ON;
INSERT INTO dbo.OrderItems (id, order_id, product_id, quantity, unit_price) VALUES
    -- Order 1: Alice - Electronics (total 229.97)
    (1,  1, 1, 1, 29.99),   -- Wireless Mouse
    (2,  1, 2, 1, 149.99),  -- Mechanical Keyboard
    (3,  1, 3, 1, 49.99),   -- USB-C Hub
    -- Order 2: Bob - Books (total 84.98)
    (4,  2, 5, 1, 39.99),   -- Clean Code
    (5,  2, 6, 1, 44.99),   -- Design Patterns
    -- Order 3: Alice - Electronics (total 49.99)
    (6,  3, 3, 1, 49.99),   -- USB-C Hub
    -- Order 4: Charlie - Monitor + Clothes (total 489.98)
    (7,  4, 4, 1, 399.99),  -- 27" Monitor
    (8,  4, 10, 1, 89.99),  -- Running Shoes
    -- Order 5: Diana - Clothing (total 59.99)
    (9,  5, 9, 1, 59.99),   -- Denim Jeans
    -- Order 6: Edward - Electronics + Clothing (total 179.98)
    (10, 6, 1, 2, 29.99),   -- Wireless Mouse x2
    (11, 6, 10, 1, 89.99),  -- Running Shoes
    (12, 6, 8, 1, 19.99),   -- Cotton T-Shirt (extra, adjusting total below)
    -- Order 7: Bob - Book (total 39.99)
    (13, 7, 7, 1, 42.99),   -- The Pragmatic Programmer (price mismatch for variety)
    -- Order 8: Charlie - Clothing (total 149.98)
    (14, 8, 9, 1, 59.99),   -- Denim Jeans
    (15, 8, 10, 1, 89.99),  -- Running Shoes
    -- Extra items for variety
    (16, 1, 5, 1, 39.99),   -- Clean Code added to Order 1
    (17, 4, 8, 2, 19.99),   -- Cotton T-Shirt x2 added to Order 4
    (18, 6, 3, 1, 49.99),   -- USB-C Hub added to Order 6
    (19, 2, 7, 1, 42.99),   -- Pragmatic Programmer added to Order 2
    (20, 5, 8, 2, 19.99);   -- Cotton T-Shirt x2 added to Order 5
SET IDENTITY_INSERT dbo.OrderItems OFF;
GO

-- Verify
SELECT 'Categories' AS TableName, COUNT(*) AS RowCount FROM dbo.Categories
UNION ALL
SELECT 'Products',   COUNT(*) FROM dbo.Products
UNION ALL
SELECT 'Customers',  COUNT(*) FROM dbo.Customers
UNION ALL
SELECT 'Orders',     COUNT(*) FROM dbo.Orders
UNION ALL
SELECT 'OrderItems', COUNT(*) FROM dbo.OrderItems;
GO
