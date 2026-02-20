#!/bin/bash
# ============================================================
# 03 — Deploy DAB to Azure Container Apps
# ============================================================
# Builds the Docker image, pushes to ACR, and deploys to
# Azure Container Apps with the SQL connection string.
#
# Usage:
#   scripts/03-deploy-container-app.sh
#
# Prerequisites:
#   - Docker running locally (or use ACR build)
#   - Azure SQL resources created (01 + 02 scripts)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Parameters ───────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sql-mcp}"
LOCATION="${LOCATION:-northeurope}"
SQL_SERVER_NAME="${SQL_SERVER_NAME:-sql-mcp-$(az account show --query user.name -o tsv | cut -d@ -f1)}"
SQL_FQDN="${SQL_SERVER_NAME}.database.windows.net"
SQL_DATABASE="${SQL_DATABASE:-OrdersDB}"

ACR_NAME="${ACR_NAME:-sqlmcpacr$(az account show --query user.name -o tsv | cut -d@ -f1 | tr -d '.')}"
CONTAINER_APP_ENV="${CONTAINER_APP_ENV:-sql-mcp-env}"
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:-sql-mcp-dab}"
IMAGE_NAME="sql-mcp-dab"
IMAGE_TAG="latest"

# DAB connection string (Azure AD managed identity auth)
DB_CONN_STRING="Server=${SQL_FQDN};Database=${SQL_DATABASE};Authentication=Active Directory Default;TrustServerCertificate=true;"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   SQL MCP Server — Container App Deployment             ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Resource Group  : $RESOURCE_GROUP"
echo "║ ACR             : $ACR_NAME"
echo "║ Container App   : $CONTAINER_APP_NAME"
echo "║ Location        : $LOCATION"
echo "║ SQL Server      : $SQL_FQDN"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Create Azure Container Registry ──────────────────────
echo "▶ Creating Azure Container Registry..."
az acr create \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Basic \
  --admin-enabled true \
  --output none

ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer -o tsv)
echo "  → ACR: $ACR_LOGIN_SERVER"

# ── 2. Build image in ACR (no local Docker needed) ──────────
echo "▶ Building Docker image in ACR..."
az acr build \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "${IMAGE_NAME}:${IMAGE_TAG}" \
  --file "$PROJECT_DIR/Dockerfile" \
  "$PROJECT_DIR"

# ── 3. Create Container App Environment ─────────────────────
echo "▶ Creating Container App Environment..."
az containerapp env create \
  --name "$CONTAINER_APP_ENV" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# ── 4. Get ACR credentials ──────────────────────────────────
ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)

# ── 5. Deploy Container App ─────────────────────────────────
echo "▶ Deploying Container App..."
az containerapp create \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$CONTAINER_APP_ENV" \
  --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}" \
  --registry-server "$ACR_LOGIN_SERVER" \
  --registry-username "$ACR_USERNAME" \
  --registry-password "$ACR_PASSWORD" \
  --target-port 5000 \
  --ingress external \
  --min-replicas 0 \
  --max-replicas 1 \
  --cpu 0.5 \
  --memory 1.0Gi \
  --env-vars "DATABASE_CONNECTION_STRING=${DB_CONN_STRING}" \
  --output none

# ── 6. Enable system-assigned managed identity ───────────────
echo "▶ Enabling managed identity..."
IDENTITY_PRINCIPAL=$(az containerapp identity assign \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --system-assigned \
  --query principalId -o tsv)

echo "  → Principal ID: $IDENTITY_PRINCIPAL"

# ── 7. Grant SQL access to managed identity ──────────────────
echo "▶ Granting SQL access to Container App identity..."
echo "  ⚠ Run the following T-SQL on $SQL_DATABASE as an AD admin:"
echo ""
echo "    CREATE USER [$CONTAINER_APP_NAME] FROM EXTERNAL PROVIDER;"
echo "    ALTER ROLE db_datareader ADD MEMBER [$CONTAINER_APP_NAME];"
echo "    ALTER ROLE db_datawriter ADD MEMBER [$CONTAINER_APP_NAME];"
echo ""

# ── 8. Get the app URL ───────────────────────────────────────
APP_FQDN=$(az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

MCP_URL="https://${APP_FQDN}/mcp"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Container App deployed!"
echo ""
echo "  App URL  : https://${APP_FQDN}"
echo "  REST API : https://${APP_FQDN}/api"
echo "  GraphQL  : https://${APP_FQDN}/graphql"
echo "  MCP      : ${MCP_URL}"
echo ""
echo "Update your .env:"
echo "  MCP_SERVER_URL=${MCP_URL}"
echo "  SQL_SERVER=${SQL_FQDN}"
echo "  SQL_DATABASE=${SQL_DATABASE}"
echo ""
echo "Test: curl https://${APP_FQDN}/api/Product"
echo "════════════════════════════════════════════════════════════"
