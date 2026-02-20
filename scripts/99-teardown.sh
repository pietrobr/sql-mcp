#!/bin/bash
# ============================================================
# 99 — Teardown: delete all Azure resources
# ============================================================
# Deletes the entire resource group and everything in it.
#
# Usage:
#   scripts/99-teardown.sh
# ============================================================

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sql-mcp}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   SQL MCP Server — Teardown                             ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Resource Group : $RESOURCE_GROUP"
echo "║                                                         ║"
echo "║ ⚠  This will DELETE all resources in the group!         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# List what will be deleted
echo "Resources in $RESOURCE_GROUP:"
az resource list --resource-group "$RESOURCE_GROUP" --query "[].{Name:name, Type:type}" -o table 2>/dev/null || true
echo ""

read -p "Are you sure you want to delete everything? (y/N) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "▶ Deleting resource group $RESOURCE_GROUP..."
    az group delete \
      --name "$RESOURCE_GROUP" \
      --yes \
      --no-wait
    echo ""
    echo "✅ Deletion started (async). Resources will be removed in a few minutes."
    echo "   Monitor: az group show --name $RESOURCE_GROUP --query properties.provisioningState -o tsv"
else
    echo "Cancelled."
fi
