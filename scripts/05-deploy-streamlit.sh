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
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:-sql-mcp-tracer}"
DAB_APP_NAME="${DAB_APP_NAME:-sql-mcp-dab}"
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
echo "║ DAB App         : $DAB_APP_NAME"
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

# ── 3. Auto-detect Container App Environment from DAB app ───
echo "▶ Detecting Container App Environment..."
CONTAINER_APP_ENV=$(az containerapp show --name "$DAB_APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --query "properties.environmentId" -o tsv 2>/dev/null | xargs -I{} basename {} || echo "")

if [ -z "$CONTAINER_APP_ENV" ]; then
    CONTAINER_APP_ENV="${CONTAINER_APP_ENV:-sql-mcp-env}"
    echo "  Could not detect env from DAB app, using default: $CONTAINER_APP_ENV"
    # Ensure it exists and is healthy
    ENV_STATE=$(az containerapp env show --name "$CONTAINER_APP_ENV" --resource-group "$RESOURCE_GROUP" \
      --query "properties.provisioningState" -o tsv 2>/dev/null || echo "")
    if [ "$ENV_STATE" != "Succeeded" ]; then
        echo "  Creating Container App Environment..."
        az containerapp env create \
          --name "$CONTAINER_APP_ENV" \
          --resource-group "$RESOURCE_GROUP" \
          --location "$LOCATION" \
          --output none
    fi
else
    echo "  Detected environment: $CONTAINER_APP_ENV (from $DAB_APP_NAME)"
fi

# ── 4. Get ACR credentials ──────────────────────────────────
ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)

# ── 5. Auto-detect MCP_SERVER_URL if not set ─────────────────
if [ -z "$MCP_SERVER_URL" ]; then
    DAB_FQDN=$(az containerapp show --name "$DAB_APP_NAME" --resource-group "$RESOURCE_GROUP" \
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
fi

echo "▶ Granting SQL access (data reader + Query Store permissions)..."
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
    'GRANT VIEW DATABASE STATE TO [$CONTAINER_APP_NAME]',
    'GRANT ALTER ON DATABASE::[$SQL_DATABASE] TO [$CONTAINER_APP_NAME]',
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
" 2>&1 || {
    echo "  ⚠ Auto-grant failed. Run these T-SQL statements manually on $SQL_DATABASE:"
    echo "    CREATE USER [$CONTAINER_APP_NAME] FROM EXTERNAL PROVIDER;"
    echo "    ALTER ROLE db_datareader ADD MEMBER [$CONTAINER_APP_NAME];"
    echo "    GRANT VIEW DATABASE STATE TO [$CONTAINER_APP_NAME];"
    echo "    GRANT ALTER ON DATABASE::[$SQL_DATABASE] TO [$CONTAINER_APP_NAME];"
}

# ── 9. Grant AI Foundry RBAC to managed identity ─────────────
# The Container App needs these roles to create and run AI agents.
# Derives the AI Services resource from PROJECT_ENDPOINT.
if [ -n "$PROJECT_ENDPOINT" ] && [ -n "$IDENTITY_PRINCIPAL" ]; then
    echo "▶ Granting AI Foundry RBAC roles..."

    # Parse PROJECT_ENDPOINT: https://<resource>.services.ai.azure.com/api/projects/<project>
    AI_RESOURCE_NAME=$(echo "$PROJECT_ENDPOINT" | sed -n 's|https://\([^.]*\)\.services\.ai\.azure\.com.*|\1|p')
    AI_PROJECT_NAME=$(echo "$PROJECT_ENDPOINT" | sed -n 's|.*/api/projects/\([^/]*\).*|\1|p')

    if [ -n "$AI_RESOURCE_NAME" ]; then
        # Find the full resource ID (may be in a different resource group)
        AI_RESOURCE_ID=$(az cognitiveservices account list \
          --query "[?name=='$AI_RESOURCE_NAME'].id | [0]" -o tsv 2>/dev/null || echo "")

        if [ -z "$AI_RESOURCE_ID" ]; then
            echo "  ⚠ Could not find AI Services resource '$AI_RESOURCE_NAME'. Assign roles manually."
        else
            echo "  AI Services resource: $AI_RESOURCE_ID"

            # Roles needed at the AI Services resource (account) level
            for ROLE in "Azure AI User" "Azure AI Developer" "Cognitive Services OpenAI User" "Cognitive Services User"; do
                az role assignment create \
                  --assignee "$IDENTITY_PRINCIPAL" \
                  --role "$ROLE" \
                  --scope "$AI_RESOURCE_ID" \
                  --output none 2>/dev/null && echo "  ✓ $ROLE (resource)" \
                  || echo "  · $ROLE (resource) — already assigned or failed"
            done

            # Azure AI User also needed at project scope
            if [ -n "$AI_PROJECT_NAME" ]; then
                PROJECT_SCOPE="${AI_RESOURCE_ID}/projects/${AI_PROJECT_NAME}"
                az role assignment create \
                  --assignee "$IDENTITY_PRINCIPAL" \
                  --role "Azure AI User" \
                  --scope "$PROJECT_SCOPE" \
                  --output none 2>/dev/null && echo "  ✓ Azure AI User (project)" \
                  || echo "  · Azure AI User (project) — already assigned or failed"
            fi
        fi
    else
        echo "  ⚠ Could not parse AI resource name from PROJECT_ENDPOINT."
    fi
else
    if [ -z "$PROJECT_ENDPOINT" ]; then
        echo "  ℹ PROJECT_ENDPOINT not set — skipping AI Foundry RBAC."
    fi
fi

# ── 10. Get the app URL ──────────────────────────────────────
APP_FQDN=$(az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Streamlit Query Tracer deployed!"
echo ""
echo "  URL : https://${APP_FQDN}"
echo "════════════════════════════════════════════════════════════"
