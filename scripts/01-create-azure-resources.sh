#!/bin/bash
# ============================================================
# 01 — Create Azure resources (Resource Group, SQL Server, DB)
# ============================================================
# Usage:
#   chmod +x scripts/01-create-azure-resources.sh
#   scripts/01-create-azure-resources.sh
#
# Override defaults with environment variables:
#   RESOURCE_GROUP=my-rg LOCATION=westeurope SQL_SERVER_NAME=my-sql \
#     scripts/01-create-azure-resources.sh
# ============================================================

set -euo pipefail

# ── Parameters (override via env vars) ───────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sql-mcp}"
LOCATION="${LOCATION:-northeurope}"
SQL_SERVER_NAME="${SQL_SERVER_NAME:-sql-mcp-$(az account show --query user.name -o tsv | cut -d@ -f1)}"
SQL_DATABASE="${SQL_DATABASE:-OrdersDB}"
ADMIN_OBJECT_ID="${ADMIN_OBJECT_ID:-$(az ad signed-in-user show --query id -o tsv)}"
ADMIN_LOGIN="${ADMIN_LOGIN:-$(az ad signed-in-user show --query userPrincipalName -o tsv)}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   SQL MCP Server — Azure Resource Setup                 ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Resource Group : $RESOURCE_GROUP"
echo "║ Location       : $LOCATION"
echo "║ SQL Server     : $SQL_SERVER_NAME"
echo "║ Database       : $SQL_DATABASE"
echo "║ Admin          : $ADMIN_LOGIN"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Resource Group ────────────────────────────────────────
echo "▶ Creating resource group..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# ── 2. Azure SQL Server (Azure AD-only auth) ────────────────
echo "▶ Creating SQL Server (Azure AD-only)..."
az sql server create \
  --name "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --enable-ad-only-auth \
  --external-admin-principal-type User \
  --external-admin-name "$ADMIN_LOGIN" \
  --external-admin-sid "$ADMIN_OBJECT_ID" \
  --output none

# ── 3. Enable public network access ─────────────────────────
echo "▶ Enabling public network access..."
az sql server update \
  --name "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --enable-public-network true \
  --output none

# ── 4. Firewall: allow Azure services ───────────────────────
echo "▶ Adding firewall rule for Azure services..."
az sql server firewall-rule create \
  --server "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name "AllowAzureServices" \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0 \
  --output none

# ── 5. Firewall: allow current client IP ────────────────────
echo "▶ Detecting your public IP..."
MY_IP=$(curl -s https://api.ipify.org)
echo "  → IP: $MY_IP"
az sql server firewall-rule create \
  --server "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name "AllowClientIP" \
  --start-ip-address "$MY_IP" \
  --end-ip-address "$MY_IP" \
  --output none

# ── 6. Create database ──────────────────────────────────────
echo "▶ Creating database $SQL_DATABASE (Basic tier)..."
az sql db create \
  --server "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SQL_DATABASE" \
  --edition GeneralPurpose \
  --family Gen5 \
  --compute-model Serverless \
  --auto-pause-delay 60 \
  --min-capacity 0.5 \
  --capacity 1 \
  --output none

# ── 7. Enable Query Store (CAPTURE ALL) ─────────────────────
echo "▶ Enabling Query Store (CAPTURE ALL)..."
# Use REST API since sqlcmd may not be installed
TOKEN=$(az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
# We'll configure Query Store in the seed script via sqlcmd/pyodbc

# ── Done ─────────────────────────────────────────────────────
SQL_FQDN="${SQL_SERVER_NAME}.database.windows.net"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Azure resources created!"
echo ""
echo "  SQL Server : $SQL_FQDN"
echo "  Database   : $SQL_DATABASE"
echo "  Auth       : Azure AD-only (admin: $ADMIN_LOGIN)"
echo ""
echo "Next steps:"
echo "  1. Run: scripts/02-seed-database.sh"
echo "  2. Run: scripts/03-deploy-container-app.sh"
echo ""
echo "Connection string for DAB (.env):"
echo "  Server=$SQL_FQDN;Database=$SQL_DATABASE;Authentication=Active Directory Default;TrustServerCertificate=true;"
echo "════════════════════════════════════════════════════════════"
