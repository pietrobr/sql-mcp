#!/bin/bash
# ============================================================
# 05 — Deploy Streamlit Query Tracer to Azure Container Apps
# ============================================================
# Builds the Streamlit Docker image in ACR and deploys it to
# Azure Container Apps alongside the DAB container.
#
# Usage:
#   scripts/05-deploy-streamlit.sh
#
# Prerequisites:
#   - ACR and Container App Environment already created (script 03)
#   - Azure SQL resources created (scripts 01 + 02)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Parameters ───────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sql-mcp}"
LOCATION="${LOCATION:-northeurope}"
CURRENT_USER=$(az account show --query user.name -o tsv | cut -d@ -f1)

SQL_SERVER_NAME="${SQL_SERVER_NAME:-sql-mcp-${CURRENT_USER}}"
SQL_FQDN="${SQL_SERVER_NAME}.database.windows.net"
SQL_DATABASE="${SQL_DATABASE:-OrdersDB}"

ACR_NAME="${ACR_NAME:-sqlmcpacr$(echo "$CURRENT_USER" | tr -d '.')}"
CONTAINER_APP_ENV="${CONTAINER_APP_ENV:-sql-mcp-env}"
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:-sql-mcp-tracer}"
IMAGE_NAME="sql-mcp-tracer"
IMAGE_TAG="latest"

# AI Foundry settings (for the embedded agent runner)
PROJECT_ENDPOINT="${PROJECT_ENDPOINT:-}"
MODEL_DEPLOYMENT_NAME="${MODEL_DEPLOYMENT_NAME:-gpt-4o}"
MCP_SERVER_URL="${MCP_SERVER_URL:-}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   SQL MCP Server — Streamlit Tracer Deployment          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Resource Group  : $RESOURCE_GROUP"
echo "║ ACR             : $ACR_NAME"
echo "║ Container App   : $CONTAINER_APP_NAME"
echo "║ SQL Server      : $SQL_FQDN"
echo "║ SQL Database    : $SQL_DATABASE"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Ensure ACR exists ────────────────────────────────────
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
fi
echo "  ACR: $ACR_LOGIN_SERVER"

# ── 2. Build Streamlit image in ACR ─────────────────────────
echo "▶ Building Streamlit Docker image in ACR..."
az acr build \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "${IMAGE_NAME}:${IMAGE_TAG}" \
  --file "$PROJECT_DIR/Dockerfile.streamlit" \
  "$PROJECT_DIR"

# ── 3. Ensure Container App Environment exists ──────────────
ENV_EXISTS=$(az containerapp env show --name "$CONTAINER_APP_ENV" --resource-group "$RESOURCE_GROUP" --query name -o tsv 2>/dev/null || echo "")
if [ -z "$ENV_EXISTS" ]; then
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

# ── 5. Auto-detect MCP_SERVER_URL if not set ─────────────────
if [ -z "$MCP_SERVER_URL" ]; then
    DAB_APP="${CONTAINER_APP_NAME/tracer/dab}"
    DAB_FQDN=$(az containerapp show --name "$DAB_APP" --resource-group "$RESOURCE_GROUP" \
      --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || echo "")
    if [ -n "$DAB_FQDN" ]; then
        MCP_SERVER_URL="https://${DAB_FQDN}/mcp"
        echo "  Auto-detected MCP URL: $MCP_SERVER_URL"
    fi
fi

# ── 6. Build env vars list ───────────────────────────────────
ENV_VARS="SQL_SERVER=${SQL_FQDN} SQL_DATABASE=${SQL_DATABASE} ODBC_DRIVER=ODBC Driver 17 for SQL Server"
if [ -n "$PROJECT_ENDPOINT" ]; then
    ENV_VARS="$ENV_VARS PROJECT_ENDPOINT=${PROJECT_ENDPOINT}"
fi
if [ -n "$MODEL_DEPLOYMENT_NAME" ]; then
    ENV_VARS="$ENV_VARS MODEL_DEPLOYMENT_NAME=${MODEL_DEPLOYMENT_NAME}"
fi
if [ -n "$MCP_SERVER_URL" ]; then
    ENV_VARS="$ENV_VARS MCP_SERVER_URL=${MCP_SERVER_URL}"
fi

# ── 7. Deploy Container App ─────────────────────────────────
echo "▶ Deploying Streamlit Container App..."

# Check if app already exists (update vs create)
APP_EXISTS=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --query name -o tsv 2>/dev/null || echo "")

if [ -n "$APP_EXISTS" ]; then
    echo "  Updating existing app..."
    az containerapp update \
      --name "$CONTAINER_APP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}" \
      --set-env-vars $ENV_VARS \
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
      --target-port 8501 \
      --ingress external \
      --min-replicas 0 \
      --max-replicas 1 \
      --cpu 0.5 \
      --memory 1.0Gi \
      --env-vars $ENV_VARS \
      --output none
fi

# ── 8. Enable managed identity & grant SQL access ───────────
echo "▶ Enabling managed identity..."
IDENTITY_PRINCIPAL=$(az containerapp identity assign \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --system-assigned \
  --query principalId -o tsv 2>/dev/null || echo "")

if [ -n "$IDENTITY_PRINCIPAL" ]; then
    echo "  Principal ID: $IDENTITY_PRINCIPAL"
    echo ""
    echo "  ⚠ Grant SQL access — run this T-SQL on $SQL_DATABASE as AD admin:"
    echo ""
    echo "    CREATE USER [$CONTAINER_APP_NAME] FROM EXTERNAL PROVIDER;"
    echo "    ALTER ROLE db_datareader ADD MEMBER [$CONTAINER_APP_NAME];"
    echo ""
fi

# ── 9. Get the app URL ───────────────────────────────────────
APP_FQDN=$(az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Streamlit Query Tracer deployed!"
echo ""
echo "  URL : https://${APP_FQDN}"
echo ""
echo "  ⚠ Remember to grant SQL read access to the managed identity:"
echo "    CREATE USER [$CONTAINER_APP_NAME] FROM EXTERNAL PROVIDER;"
echo "    ALTER ROLE db_datareader ADD MEMBER [$CONTAINER_APP_NAME];"
echo "════════════════════════════════════════════════════════════"
