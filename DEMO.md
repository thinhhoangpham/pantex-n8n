# Inventory Multi-Agent Pipeline — Demo Guide

## Prerequisites

Start both containers:

```bash
docker compose up -d
```

Verify the DuckDB service is healthy:

```bash
curl -s http://localhost:8001/health | python3 -m json.tool
```

```bash
mkdir -p demo-output
```

---

## Demo 1: Query Source Data (Query Agent)

Direct calls to the Query Agent to inspect source data without running the full pipeline.

List all tables in source.duckdb:

```bash
curl -s -X POST http://localhost:5678/webhook/query-agent \
  -H "Content-Type: application/json" \
  -d '{"task": "List all tables", "database": "/data/source.duckdb"}' \
  | python3 -m json.tool > demo-output/demo1-tables.json && echo "Saved to demo-output/demo1-tables.json"
```

Query the first 5 products with their reorder points:

```bash
curl -s -X POST http://localhost:5678/webhook/query-agent \
  -H "Content-Type: application/json" \
  -d '{"task": "Show the first 5 products with their reorder points", "database": "/data/source.duckdb"}' \
  | python3 -m json.tool > demo-output/demo1-products.json && echo "Saved to demo-output/demo1-products.json"
```

---

## Demo 2: Full Build (Path A — BUILD_ALL)

First-time question where nothing exists in the vault yet. The dispatcher builds all vault tables and the mart from scratch.

Optionally reset the vault first to guarantee a true from-scratch build (see [Reset](#reset-drop-all-vault-tables) section below):

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT name FROM (SHOW TABLES)", "database": "/data/vault.duckdb"}' \
  | python3 -c "
import sys, json, urllib.request
tables = [r['name'] for r in json.load(sys.stdin)['rows']]
if not tables:
    print('No tables to drop')
else:
    stmts = ['DROP TABLE IF EXISTS ' + t for t in tables]
    req = urllib.request.Request('http://localhost:8001/execute-batch',
        data=json.dumps({'statements': stmts, 'database': '/data/vault.duckdb'}).encode(),
        headers={'Content-Type': 'application/json'})
    resp = json.load(urllib.request.urlopen(req))
    print(f'Dropped {resp[\"succeeded\"]}/{resp[\"total\"]} tables: {tables}')
"
```

Then run the dispatcher:

```bash
curl -s -X POST http://localhost:5678/webhook/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "Which products are below reorder point and which vendors supply them?"}' \
  | python3 -m json.tool > demo-output/demo2-build-all.json && echo "Saved to demo-output/demo2-build-all.json"
```

What to observe in the response:

- `routing: "BUILD_ALL"` — all build agents were invoked
- `vault_tables_created` lists hubs from both ERP and Procurement: hub_product, hub_location, hub_vendor, lnk_product_location, lnk_product_vendor, sat_product_details, sat_vendor_details, etc.
- `source_tables_extracted` shows tables from both the erp and procurement schemas
- `existing_tables_reused: []` — nothing existed before
- `dq_status: "pass"` — Data Quality gate passed
- `output.data` contains rows with product_name, vendor_name, current stock levels, and reorder points — data that spans two source systems
- `timings` shows how long each agent took
- `generated_sql` contains the full DDL and load SQL for all vault and mart tables

Note: This path takes 15–30 seconds due to multiple LLM calls and SQL execution.

Why this matters: This question requires joining data across ERP (products, inventory levels) and Procurement (vendors, purchase orders) — two separate source systems. The pipeline extracts from both, models them into a unified Data Vault, and builds a mart that joins them. A simple query against a single source schema cannot answer this.

---

## Demo 3: Instant Query (Path B — QUERY_ONLY)

Same question as Demo 2, but the mart already exists and is fresh. The dispatcher skips all build agents and queries the existing mart directly.

Run the exact same command:

```bash
curl -s -X POST http://localhost:5678/webhook/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "Which products are below reorder point and which vendors supply them?"}' \
  | python3 -m json.tool > demo-output/demo3-query-only.json && echo "Saved to demo-output/demo3-query-only.json"
```

What to observe in the response:

- `routing: "QUERY_ONLY"` — all build agents were skipped
- Same data returned, near-instantly
- No `vault_tables_created` field — existing tables were reused

---

## Demo 4: Incremental Build (Path C — PARTIAL_BUILD)

A new question that adds WMS data — a third source system — on top of the existing vault. The dispatcher reuses all product and vendor vault tables built in Demo 2 and adds only the new warehouse-related tables.

```bash
curl -s -X POST http://localhost:5678/webhook/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "Show stock movement history for products that are below reorder point by warehouse"}' \
  | python3 -m json.tool > demo-output/demo4-partial-build.json && echo "Saved to demo-output/demo4-partial-build.json"
```

What to observe in the response:

- `routing: "PARTIAL_BUILD"` — only missing tables were built
- `vault_tables_created` shows only WMS-related tables: hub_warehouse, lnk_product_warehouse, sat_stock_movements, etc.
- `existing_tables_reused` shows the product and vendor tables carried over from Demo 2: hub_product, hub_vendor, sat_product_details, etc.
- `source_tables_extracted` shows only wms.* tables — ERP and Procurement data was already in the vault and was not re-extracted
- `timings` shows the build was faster since it skipped already-existing tables

Why this matters: This question adds a third source system (WMS) to the existing vault. The pipeline doesn't rebuild the ERP and Procurement data — it incrementally adds only what's new. This demonstrates how the Data Vault grows over time without redundant rebuilds.

Note: This demo may occasionally fail DQ due to LLM SQL generation errors. If it does, the response will show `status: "error"` with a `dq_issues` field explaining what failed — this demonstrates the Data Quality gate working as intended.

---

## Demo 5: Inspect the Vault

Direct queries against vault.duckdb to verify what was built by the pipeline.

Show all mart tables currently in the vault:

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT table_name FROM information_schema.tables WHERE table_schema = '\''main'\'' AND table_name LIKE '\''mart_%'\''", "database": "/data/vault.duckdb"}' \
  | python3 -m json.tool > demo-output/demo5-mart-tables.json && echo "Saved to demo-output/demo5-mart-tables.json"
```

Count rows in the product hub:

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT COUNT(*) FROM hub_product", "database": "/data/vault.duckdb"}' \
  | python3 -m json.tool > demo-output/demo5-hub-count.json && echo "Saved to demo-output/demo5-hub-count.json"
```

Sample cross-system data by joining the product hub with its satellite — this data originates from the ERP schema but is now modeled in the vault:

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT hp.product_bk, spd.product_name, spd.sku FROM hub_product hp JOIN sat_product_details spd ON hp.product_hk = spd.product_hk WHERE spd.load_end_dts IS NULL LIMIT 5", "database": "/data/vault.duckdb"}' \
  | python3 -m json.tool > demo-output/demo5-vault-data.json && echo "Saved to demo-output/demo5-vault-data.json"
```

---

## Reset: Drop All Vault Tables

Wipe the entire vault to start fresh. Useful before Demo 2 to guarantee a BUILD_ALL path.

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT name FROM (SHOW TABLES)", "database": "/data/vault.duckdb"}' \
  | python3 -c "
import sys, json, urllib.request
tables = [r['name'] for r in json.load(sys.stdin)['rows']]
if not tables:
    print('No tables to drop')
else:
    stmts = ['DROP TABLE IF EXISTS ' + t for t in tables]
    req = urllib.request.Request('http://localhost:8001/execute-batch',
        data=json.dumps({'statements': stmts, 'database': '/data/vault.duckdb'}).encode(),
        headers={'Content-Type': 'application/json'})
    resp = json.load(urllib.request.urlopen(req))
    print(f'Dropped {resp[\"succeeded\"]}/{resp[\"total\"]} tables: {tables}')
"
```

---

## Demo 6: MCP Server (Claude Desktop Integration)

Connect Claude Desktop to the pipeline via the Model Context Protocol. Once configured, Claude Desktop can call three inventory tools directly from a conversation.

**Prerequisite:** `docker compose up -d` must be running and all workflows must be active in n8n.

### Configure Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (create it if it does not exist):

```json
{
  "mcpServers": {
    "inventory": {
      "url": "http://localhost:5678/mcp/inventory-tools/sse"
    }
  }
}
```

Save the file, then restart Claude Desktop. The three inventory tools will appear in the tool picker.

### Available Tools

| Tool | What it does |
|---|---|
| `ask_inventory_question` | Sends a natural language question to the full Dispatcher pipeline — builds vault/mart as needed and returns results |
| `describe_schema` | Returns table listings from source.duckdb or vault.duckdb |
| `run_query` | Runs a SQL statement directly against source.duckdb or vault.duckdb |

### Example Prompts to Try

Ask in Claude Desktop after connecting:

- "What products are below reorder point?" — routes through `ask_inventory_question`, which triggers the full Dispatcher pipeline (BUILD_ALL, QUERY_ONLY, or PARTIAL_BUILD depending on vault state)
- "Describe the source database schemas" — uses `describe_schema` to list tables in source.duckdb
- "Run this SQL: SELECT * FROM erp.products LIMIT 5" — uses `run_query` to execute SQL directly against source.duckdb

The `ask_inventory_question` tool runs the same pipeline as Demo 2–4. The first call after a vault reset will be slow (15–30 seconds) while the vault and mart are built. Subsequent calls for the same question will be near-instant (QUERY_ONLY path).

---

## Tips

- All demo output is saved to the `demo-output/` directory as JSON files for easy inspection.
- BUILD_ALL (Demo 2) takes 15–30 seconds — multiple LLM calls are made in sequence before SQL is executed.
- QUERY_ONLY (Demo 3) is near-instant — no LLM calls, just a direct mart query.
- If a dispatcher call fails, check that the Query Agent, Data Vault Agent, Info Mart Agent, and Data Quality Agent workflows are all active in n8n at `http://localhost:5678`.
- If Claude Desktop does not show the inventory tools, verify n8n is running (`docker compose ps`) and restart Claude Desktop after saving the config file.
