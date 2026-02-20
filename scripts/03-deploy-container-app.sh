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

# ── 1. Ensure Azure Container Registry exists ───────────────
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer -o tsv 2>/dev/null || echo "")
if [ -z "$ACR_LOGIN_SERVER" ]; then
    echo "▶ Creating Azure Container Registry..."
    az acr create \
      --name "$ACR_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --sku Basic \
      --admin-enabled true \
      --output none
    ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer -o tsv)
else
    echo "  ACR already exists."
fi
echo "  → ACR: $ACR_LOGIN_SERVER"

# ── 2. Build image in ACR (no local Docker needed) ──────────
echo "▶ Building Docker image in ACR..."
az acr build \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "${IMAGE_NAME}:${IMAGE_TAG}" \
  --file "$PROJECT_DIR/Dockerfile" \
  "$PROJECT_DIR"

# ── 3. Ensure Container App Environment exists ──────────────
ENV_STATE=$(az containerapp env show --name "$CONTAINER_APP_ENV" --resource-group "$RESOURCE_GROUP" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "")
if [ "$ENV_STATE" = "Succeeded" ]; then
    echo "  Container App Environment already exists."
else
    echo "▶ Creating Container App Environment..."
    az containerapp env create \
      --name "$CONTAINER_APP_ENV" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --output none
fi

# ── 4. Get ACR credentials ──────────────────────────────────
ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)

# ── 5. Deploy Container App ─────────────────────────────────
echo "▶ Deploying Container App..."
APP_EXISTS=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --query name -o tsv 2>/dev/null || echo "")
if [ -n "$APP_EXISTS" ]; then
    echo "  Updating existing app..."
    az containerapp update \
      --name "$CONTAINER_APP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}" \
      --set-env-vars "DATABASE_CONNECTION_STRING=${DB_CONN_STRING}" \
      --output none
else
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
fi

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
TOKEN=$(az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
export SQL_TOKEN="$TOKEN"
python3 -c "
import struct, pyodbc, os
token = os.environ['SQL_TOKEN']
raw = token.encode('UTF-16-LE')
token_struct = struct.pack(f'<I{len(raw)}s', len(raw), raw)
conn = pyodbc.connect(
    'Driver={ODBC Driver 17 for SQL Server};'
    'Server=$SQL_FQDN;Database=$SQL_DATABASE;'
    'Encrypt=yes;TrustServerCertificate=no;',
    attrs_before={1256: token_struct},
    autocommit=True,
)
cursor = conn.cursor()
for sql in [
    'CREATE USER [$CONTAINER_APP_NAME] FROM EXTERNAL PROVIDER',
    'ALTER ROLE db_datareader ADD MEMBER [$CONTAINER_APP_NAME]',
    'ALTER ROLE db_datawriter ADD MEMBER [$CONTAINER_APP_NAME]',
]:
    try:
        cursor.execute(sql)
        print(f'  OK: {sql}')
    except Exception as e:
        if '15023' in str(e) or '15378' in str(e):
            print(f'  Already exists: {sql}')
        else:
            print(f'  WARN: {sql} -> {e}')
conn.close()
" 2>&1 || echo "  ⚠ Auto-grant failed. Run manually:"
echo "    CREATE USER [$CONTAINER_APP_NAME] FROM EXTERNAL PROVIDER;"
echo "    ALTER ROLE db_datareader ADD MEMBER [$CONTAINER_APP_NAME];"
echo "    ALTER ROLE db_datawriter ADD MEMBER [$CONTAINER_APP_NAME];"

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
