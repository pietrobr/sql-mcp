# SQL MCP Server — Test Project

Test project for **Data API Builder (DAB) SQL MCP Server** with an **Azure AI Foundry** agent.

## Architecture

```
Azure AI Foundry Agent (GPT-4o)
        ↓ MCP protocol
SQL MCP Server (DAB v1.7)
        ↓ T-SQL (deterministic)
Azure SQL Database (OrdersDB)
```

## Database Schema

| Table | Description | Rows |
|---|---|---|
| `dbo.Categories` | Product categories (Electronics, Books, Clothing) | 3 |
| `dbo.Products` | Products with prices, linked to categories | 10 |
| `dbo.Customers` | Registered customers | 5 |
| `dbo.Orders` | Orders with status and totals | 8 |
| `dbo.OrderItems` | Line items linking orders to products | 20 |

### Relationships
- Category 1:M Products
- Customer 1:M Orders
- Order 1:M OrderItems
- Product 1:M OrderItems

## Prerequisites

- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az login` completed)
- Python 3.10+
- Azure AI Foundry project with GPT-4o deployed

## Quick Start

### 1. Install DAB CLI

```bash
dotnet tool install --global Microsoft.DataApiBuilder --prerelease
dab --version  # should be >= 1.7.x-rc
```

### 2. Run DAB locally

```bash
dab start --verbose
```

This starts:
- **REST**: `http://localhost:5000/api/{entity}`
- **GraphQL**: `http://localhost:5000/graphql`
- **MCP**: `http://localhost:5000/mcp`

### 3. Test REST endpoint

```bash
curl http://localhost:5000/api/Product
```

### 4. Configure the Python agent

```bash
cp .env.template .env
# Edit .env with your Azure AI Foundry project details
```

### 5. Run the test agent

```bash
pip install -r requirements.txt
python test_agent.py
```

## Deploy to Azure Container Apps

### 1. Create Azure SQL resources (already done)

```bash
# Resources already created:
# - Resource group: rg-sql-mcp
# - SQL Server: sql-mcp-pietrobr.database.windows.net
# - Database: OrdersDB
```

### 2. Deploy DAB to Container Apps

```bash
# Create Container App Environment
az containerapp env create \
  --name sql-mcp-env \
  --resource-group rg-sql-mcp \
  --location westeurope

# Build and deploy (requires Docker or ACR)
az containerapp up \
  --name sql-mcp-dab \
  --resource-group rg-sql-mcp \
  --environment sql-mcp-env \
  --source . \
  --target-port 5000 \
  --ingress external

# Update .env with the Container App URL
# MCP_SERVER_URL=https://<app-name>.<region>.azurecontainerapps.io/mcp
```

## DAB Configuration

The `dab-config.json` file controls everything:
- **Database connection**: Azure SQL with Azure AD authentication
- **Entities**: 5 entities with semantic descriptions for AI agent understanding
- **Relationships**: Cross-entity navigation (e.g., Order → Customer)
- **MCP**: Enabled at `/mcp` with all DML tools active
- **Permissions**: `anonymous:*` for testing (restrict in production)

## MCP Tools Available

The SQL MCP Server exposes 6 DML tools:

| Tool | Description |
|---|---|
| `describe_entities` | List available entities and their fields |
| `create_record` | Insert a new record |
| `read_records` | Read records with filters, pagination, sorting |
| `update_record` | Update an existing record |
| `delete_record` | Delete a record |
| `execute_entity` | Execute stored procedures |

## Key Design: NL2DAB (not NL2SQL)

The agent **never generates raw SQL**. Instead, it calls structured MCP tools → DAB's Query Builder generates deterministic T-SQL internally. This eliminates the risks of AI-generated SQL.

## Azure Resources Created

| Resource | Name |
|---|---|
| Resource Group | `rg-sql-mcp` |
| Azure SQL Server | `sql-mcp-pietrobr.database.windows.net` |
| Database | `OrdersDB` |
| Auth | Azure AD-only (no SQL auth) |

## Cleanup

```bash
az group delete --name rg-sql-mcp --yes --no-wait
```
