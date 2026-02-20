#!/bin/bash
# ============================================================
# 04 — Create AI Foundry Hub, Project & deploy GPT-4o model
# ============================================================
# Creates an Azure AI Foundry hub and project, then deploys a
# GPT-4o model so the agent in test_agent.py can run.
#
# Usage:
#   scripts/04-create-foundry-project.sh
#
# Prerequisites:
#   - Azure CLI with `ml` extension: az extension add -n ml
#   - Azure OpenAI available in your subscription
# ============================================================

set -euo pipefail

# ── Parameters ───────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sql-mcp}"
LOCATION="${LOCATION:-swedencentral}"
CURRENT_USER=$(az account show --query user.name -o tsv | cut -d@ -f1)

AI_HUB_NAME="${AI_HUB_NAME:-sql-mcp-hub-${CURRENT_USER}}"
AI_PROJECT_NAME="${AI_PROJECT_NAME:-sql-mcp-project}"
MODEL_NAME="${MODEL_NAME:-gpt-4o}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-gpt-4o}"
DEPLOYMENT_SKU="${DEPLOYMENT_SKU:-GlobalStandard}"
DEPLOYMENT_CAPACITY="${DEPLOYMENT_CAPACITY:-10}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   SQL MCP Server — AI Foundry Setup                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Resource Group : $RESOURCE_GROUP"
echo "║ Location       : $LOCATION"
echo "║ AI Hub         : $AI_HUB_NAME"
echo "║ AI Project     : $AI_PROJECT_NAME"
echo "║ Model          : $MODEL_NAME"
echo "║ Deployment     : $DEPLOYMENT_NAME"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Ensure ml extension ──────────────────────────────────
echo "▶ Checking Azure ML extension..."
az extension add --name ml --upgrade --yes 2>/dev/null || true

# ── 2. Create AI Hub ────────────────────────────────────────
echo "▶ Creating AI Foundry Hub: $AI_HUB_NAME..."
az ml workspace create \
  --kind hub \
  --name "$AI_HUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

echo "  ✓ Hub created"

# ── 3. Create AI Project ────────────────────────────────────
echo "▶ Creating AI Foundry Project: $AI_PROJECT_NAME..."
HUB_ID=$(az ml workspace show \
  --name "$AI_HUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

az ml workspace create \
  --kind project \
  --name "$AI_PROJECT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --hub-id "$HUB_ID" \
  --output none

echo "  ✓ Project created"

# ── 4. Get the AI Services / OpenAI connection ──────────────
echo "▶ Looking up AI Services connection..."
# The hub auto-creates an AI Services account; find its connection name
CONNECTION_NAME=$(az ml connection list \
  --workspace-name "$AI_HUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?properties.category=='AzureOpenAI' || properties.category=='AIServices'].name | [0]" \
  -o tsv 2>/dev/null || echo "")

if [ -z "$CONNECTION_NAME" ]; then
    echo "  ⚠ No AI Services connection found on the hub."
    echo "    The hub may still be provisioning. Wait a minute and re-run, or"
    echo "    create a connection manually in AI Foundry portal."
    echo ""
    echo "    Alternatively, create an Azure OpenAI resource and connect it:"
    echo "      az cognitiveservices account create \\"
    echo "        --name sql-mcp-aoai-${CURRENT_USER} \\"
    echo "        --resource-group $RESOURCE_GROUP \\"
    echo "        --location $LOCATION \\"
    echo "        --kind OpenAI --sku S0 --yes"
    echo ""
else
    echo "  ✓ Connection: $CONNECTION_NAME"
fi

# ── 5. Deploy GPT-4o model ──────────────────────────────────
echo "▶ Deploying model: $MODEL_NAME → $DEPLOYMENT_NAME..."

# Find the AI Services resource name from the connection or hub
AISERVICES_NAME=$(az ml connection show \
  --name "$CONNECTION_NAME" \
  --workspace-name "$AI_HUB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.metadata.ResourceId" -o tsv 2>/dev/null | xargs -I{} basename {} || echo "")

if [ -z "$AISERVICES_NAME" ]; then
    # Fallback: look for cognitive services account in the RG
    AISERVICES_NAME=$(az cognitiveservices account list \
      --resource-group "$RESOURCE_GROUP" \
      --query "[0].name" -o tsv 2>/dev/null || echo "")
fi

if [ -n "$AISERVICES_NAME" ]; then
    echo "  Using AI Services account: $AISERVICES_NAME"

    # Check if deployment already exists
    EXISTING=$(az cognitiveservices account deployment show \
      --name "$AISERVICES_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --deployment-name "$DEPLOYMENT_NAME" \
      --query "name" -o tsv 2>/dev/null || echo "")

    if [ -n "$EXISTING" ]; then
        echo "  ✓ Deployment '$DEPLOYMENT_NAME' already exists — skipping."
    else
        az cognitiveservices account deployment create \
          --name "$AISERVICES_NAME" \
          --resource-group "$RESOURCE_GROUP" \
          --deployment-name "$DEPLOYMENT_NAME" \
          --model-name "$MODEL_NAME" \
          --model-version "2024-08-06" \
          --model-format OpenAI \
          --sku-name "$DEPLOYMENT_SKU" \
          --sku-capacity "$DEPLOYMENT_CAPACITY" \
          --output none
        echo "  ✓ Model deployed"
    fi
else
    echo "  ⚠ Could not find AI Services account. Deploy the model manually:"
    echo "    1. Go to https://ai.azure.com → $AI_PROJECT_NAME → Model catalog"
    echo "    2. Select $MODEL_NAME → Deploy"
    echo "    3. Use deployment name: $DEPLOYMENT_NAME"
fi

# ── 6. Get project endpoint ─────────────────────────────────
echo ""
echo "▶ Retrieving project endpoint..."
DISCOVERY_URL=$(az ml workspace show \
  --name "$AI_PROJECT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query discovery_url -o tsv 2>/dev/null || echo "")

# The project endpoint is the discovery_url without the /discovery path
PROJECT_ENDPOINT=""
if [ -n "$DISCOVERY_URL" ]; then
    PROJECT_ENDPOINT=$(echo "$DISCOVERY_URL" | sed 's|/discovery.*||')
fi

if [ -z "$PROJECT_ENDPOINT" ]; then
    # Fallback: construct from workspace metadata
    WORKSPACE_ID=$(az ml workspace show \
      --name "$AI_PROJECT_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --query id -o tsv)
    echo "  Workspace ID: $WORKSPACE_ID"
    echo "  ⚠ Could not auto-detect endpoint. Find it at:"
    echo "    https://ai.azure.com → $AI_PROJECT_NAME → Overview → Project endpoint"
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ AI Foundry project ready!"
echo ""
echo "  Hub      : $AI_HUB_NAME"
echo "  Project  : $AI_PROJECT_NAME"
echo "  Model    : $DEPLOYMENT_NAME"
if [ -n "$PROJECT_ENDPOINT" ]; then
echo "  Endpoint : $PROJECT_ENDPOINT"
fi
echo ""
echo "Update your .env file:"
if [ -n "$PROJECT_ENDPOINT" ]; then
echo "  PROJECT_ENDPOINT=$PROJECT_ENDPOINT"
else
echo "  PROJECT_ENDPOINT=<get from AI Foundry portal>"
fi
echo "  MODEL_DEPLOYMENT_NAME=$DEPLOYMENT_NAME"
echo ""
echo "Then run: python test_agent.py"
echo "════════════════════════════════════════════════════════════"
