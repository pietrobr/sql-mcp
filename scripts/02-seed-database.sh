#!/bin/bash
# ============================================================
# 02 — Seed database (schema + sample data + Query Store)
# ============================================================
# Runs sql/setup.sql against the Azure SQL Database using sqlcmd.
# Falls back to Python/pyodbc if sqlcmd is not installed.
#
# Usage:
#   scripts/02-seed-database.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Parameters ───────────────────────────────────────────────
SQL_SERVER_NAME="${SQL_SERVER_NAME:-sql-mcp-$(az account show --query user.name -o tsv | cut -d@ -f1)}"
SQL_FQDN="${SQL_SERVER_NAME}.database.windows.net"
SQL_DATABASE="${SQL_DATABASE:-OrdersDB}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   SQL MCP Server — Database Seed                        ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Server   : $SQL_FQDN"
echo "║ Database : $SQL_DATABASE"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Get Azure AD token ───────────────────────────────────────
echo "▶ Acquiring Azure AD token..."
TOKEN=$(az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)

# ── Try sqlcmd first ─────────────────────────────────────────
if command -v sqlcmd &> /dev/null; then
    echo "▶ Running sql/setup.sql via sqlcmd..."
    sqlcmd \
      -S "$SQL_FQDN" \
      -d "$SQL_DATABASE" \
      -G \
      -i "$PROJECT_DIR/sql/setup.sql"
else
    echo "  sqlcmd not found — using Python/pyodbc fallback..."
    python -c "
import struct, pyodbc

token = '''$TOKEN'''
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

# Read and execute setup.sql (split on GO)
with open('$PROJECT_DIR/sql/setup.sql', 'r') as f:
    sql = f.read()

batches = [b.strip() for b in sql.split('\nGO\n') if b.strip()]
for i, batch in enumerate(batches, 1):
    # Skip USE/CREATE DATABASE — already connected
    upper = batch.strip().upper()
    if upper.startswith('USE ') or upper.startswith('IF NOT EXISTS (SELECT NAME FROM SYS.DATABASES'):
        continue
    try:
        cursor.execute(batch)
        print(f'  Batch {i}/{len(batches)} OK')
    except Exception as e:
        print(f'  Batch {i}/{len(batches)} WARN: {e}')

conn.close()
print('Done.')
"
fi

# ── Enable Query Store ───────────────────────────────────────
echo ""
echo "▶ Enabling Query Store (CAPTURE ALL)..."
python -c "
import struct, pyodbc

token = '''$TOKEN'''
raw = token.encode('UTF-16-LE')
token_struct = struct.pack(f'<I{len(raw)}s', len(raw), raw)
conn = pyodbc.connect(
    'Driver={ODBC Driver 17 for SQL Server};'
    'Server=$SQL_FQDN;Database=$SQL_DATABASE;'
    'Encrypt=yes;TrustServerCertificate=no;',
    attrs_before={1256: token_struct},
    autocommit=True,
)
conn.cursor().execute(
    'ALTER DATABASE [$SQL_DATABASE] SET QUERY_STORE = ON '
    '(OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL)'
)
conn.close()
print('  Query Store enabled.')
"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Database seeded and Query Store enabled!"
echo ""
echo "Verify: az sql db show --server $SQL_SERVER_NAME --resource-group \${RESOURCE_GROUP:-rg-sql-mcp} --name $SQL_DATABASE --query status -o tsv"
echo "════════════════════════════════════════════════════════════"
