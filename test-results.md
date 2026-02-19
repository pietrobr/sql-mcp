# SQL MCP Server - Agent Test Results

**Date**: 2026-02-19  
**Model**: gpt-4o  
**MCP Server**: https://sql-mcp-dab.reddune-fdb4aafa.northeurope.azurecontainerapps.io/mcp  
**Project**: pietrobr-swedenc-product-2 (Sweden Central)

---

## Query 1/5: What entities are available? Describe each one briefly.

**Result**: ✅ Success

The available entities and their brief descriptions are:

1. **Category**: Product categories used to organize the catalog. Each category groups related products.
2. **Customer**: Registered customers who can place orders. Contains name and email.
3. **Order**: Customer orders with date, total amount, and status (Pending, Processing, Shipped, Completed).
4. **OrderItem**: Line items within an order. Links an order to a product with quantity and unit price.
5. **Product**: Products available for purchase. Each product belongs to one category and has a price.

---

## Query 2/5: List the top 5 most expensive products with their category name.

**Result**: ✅ Success

Here are the top 5 most expensive products along with their category names:

| Product ID | Price  | Category Name |
|------------|--------|---------------|
| 4          | 399.99 | Electronics   |
| 2          | 149.99 | Electronics   |
| 10         | 89.99  | Clothing      |
| 9          | 59.99  | Clothing      |
| 3          | 49.99  | Electronics   |

---

## Query 3/5: How many orders does each customer have? Show customer name and order count.

**Result**: ✅ Success

| Customer Name   | Order Count |
|-----------------|-------------|
| Alice Johnson   | 2           |
| Bob Smith       | 2           |
| Charlie Brown   | 2           |
| Diana Martinez  | 1           |
| Edward Lee      | 1           |

---

## Query 4/5: What is the total revenue by product category?

**Result**: ✅ Success

The agent calculated the total revenue by joining OrderItems with Products and Categories:

### Revenue Calculation

**Electronics** (Category ID 1):
- Product 1 (Wireless Mouse): $(1 \times 29.99) + (2 \times 29.99) = 89.97$
- Product 2 (Mechanical Keyboard): $1 \times 149.99 = 149.99$
- Product 3 (USB-C Hub): $(1 \times 49.99) + (1 \times 49.99) + (1 \times 49.99) = 149.97$
- Product 4 (27" Monitor): $1 \times 399.99 = 399.99$

**Books** (Category ID 2):
- Product 5 (Clean Code): $(1 \times 39.99) + (1 \times 39.99) = 79.98$
- Product 6 (Design Patterns): $1 \times 44.99 = 44.99$
- Product 7 (The Pragmatic Programmer): $(1 \times 42.99) + (1 \times 42.99) = 85.98$

**Clothing** (Category ID 3):
- Product 8 (Cotton T-Shirt): $(1 \times 19.99) + (2 \times 19.99) + (2 \times 19.99) = 99.95$
- Product 9 (Denim Jeans): $(1 \times 59.99) + (1 \times 59.99) = 119.98$
- Product 10 (Running Shoes): $(1 \times 89.99) + (1 \times 89.99) + (1 \times 89.99) = 269.97$

| Category    | Total Revenue (USD) |
|-------------|---------------------|
| Electronics | 789.92              |
| Books       | 210.95              |
| Clothing    | 489.90              |

---

## Query 5/5: Show the details of order #4 including all its line items and product names.

**Result**: ⚠️ Partial (metadata retrieval issue on this run)

The agent encountered issues retrieving field metadata for the Order entity on this particular run. However, in a previous successful run, the agent returned:

### Order Details
- **Order ID**: 4
- **Customer ID**: 3
- **Order Date**: 2025-02-10 16:45:00
- **Total Amount**: $489.98
- **Status**: Completed

### Order Line Items
| Line Item ID | Product Name   | Quantity | Unit Price | Total Price |
|--------------|----------------|----------|------------|-------------|
| 7            | 27" Monitor    | 1        | $399.99    | $399.99     |
| 8            | Running Shoes  | 1        | $89.99     | $89.99      |
| 17           | Cotton T-Shirt | 2        | $19.99     | $39.98      |

---

## Summary

| Query | Description                          | Result  |
|-------|--------------------------------------|---------|
| 1     | List entities                        | ✅ Pass |
| 2     | Top 5 expensive products + category  | ✅ Pass |
| 3     | Orders per customer                  | ✅ Pass |
| 4     | Revenue by category                  | ✅ Pass |
| 5     | Order #4 details with line items     | ⚠️ Partial |

**Overall**: 4/5 queries fully successful, 1 partial due to intermittent metadata retrieval.

## Architecture

```
┌──────────────┐     ┌─────────────────────┐     ┌──────────────────┐
│  AI Foundry  │────▶│  SQL MCP Server     │────▶│  Azure SQL DB    │
│  Agent       │ MCP │  (DAB v1.7 on       │ SQL │  OrdersDB        │
│  (gpt-4o)    │◀────│  Container Apps)     │◀────│  5 tables        │
└──────────────┘     └─────────────────────┘     └──────────────────┘
```
