# Inventory Multi-Agent Pipeline — Demo Guide

## Prerequisites

Start both containers:

```bash
docker compose up -d
```

Verify services are healthy:

```bash
curl -s http://localhost:8001/health | python3 -m json.tool
curl -s http://localhost:5678/healthz
```

```bash
mkdir -p demo-output
```

---

## Reset: Clean Vault

Wipe the entire vault to start fresh. Run this before Demo 1 to guarantee BUILD_ALL paths.

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT table_name FROM information_schema.tables WHERE table_schema = '\''main'\'' AND table_name NOT IN ('\''_vault_registry'\'', '\''_mart_registry'\'')", "database": "/data/vault.duckdb"}' \
  | python3 -c "
import sys, json, urllib.request
tables = [r['table_name'] for r in json.load(sys.stdin).get('rows', [])]
if not tables:
    print('Vault already clean.')
else:
    stmts = ['DROP TABLE IF EXISTS \"' + t + '\"' for t in tables]
    stmts.append('DELETE FROM _vault_registry')
    stmts.append('DELETE FROM _mart_registry')
    req = urllib.request.Request('http://localhost:8001/execute-batch',
        data=json.dumps({'statements': stmts, 'database': '/data/vault.duckdb'}).encode(),
        headers={'Content-Type': 'application/json'})
    resp = json.load(urllib.request.urlopen(req))
    print(f'Dropped {len(tables)} tables, cleared registries. Failed: {resp.get(\"failed\",0)}')
"
```

---

## Demo 1: BUILD_ALL — Cross-System Vendor Analysis

A question that requires joining ERP (products, inventory) with Procurement (vendors, purchase orders). The pipeline builds the full Data Vault from scratch and creates a mart.

```bash
curl -s -X POST http://localhost:5678/webhook/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "Which products are below their reorder point? Include the vendor names that supply each product."}' \
  | python3 -m json.tool > demo-output/demo1-build-all.json && echo "Saved to demo-output/demo1-build-all.json"
```

What to observe:

- `routing: "BUILD_ALL"` — full pipeline invoked
- `vault_tables_created` — hubs (hub_product, hub_vendor, hub_location), links (lnk_product_location, lnk_product_vendor), and satellites (sat_product_details, sat_inventory_levels, sat_vendor_details)
- `source_tables_extracted` — tables from both `erp.*` and `procurement.*` schemas
- `generated_sql` — full DDL and load SQL for every vault table, plus mart DDL and populate SQL
- `query_code` — all SQL compiled into a single readable block
- `dq_status: "pass"` — vault and mart passed data quality checks
- `output.data` — products below reorder point with vendor names, combining data from two source systems

**Data Vault structure built:**
```
hub_product ← sat_product_details (product attributes)
hub_product ← lnk_product_location → hub_location
               ↑ sat_inventory_levels (qty_on_hand per product per location)
hub_product ← lnk_product_vendor → hub_vendor ← sat_vendor_details
```

---

## Demo 2: QUERY_ONLY — Instant Reuse

Same question as Demo 1. The mart already exists and is fresh (<24h), so the pipeline skips all build agents.

```bash
curl -s -X POST http://localhost:5678/webhook/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "Which products are below their reorder point? Include the vendor names that supply each product."}' \
  | python3 -m json.tool > demo-output/demo2-query-only.json && echo "Saved to demo-output/demo2-query-only.json"
```

What to observe:

- `routing: "QUERY_ONLY"` — all build agents skipped
- Same data, returned in ~5 seconds instead of ~30 seconds
- `existing_tables_reused` — lists the vault tables from Demo 1
- `query_code` — just the final SELECT query against the existing mart

---

## Demo 3: PARTIAL_BUILD — Incremental Vault Growth

A new question that adds WMS (warehouse) data on top of the existing vault. The pipeline reuses all ERP and Procurement vault tables and builds only the new WMS-related tables.

```bash
curl -s -X POST http://localhost:5678/webhook/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "Show total receipts, shipments, and adjustments for each product at each location."}' \
  | python3 -m json.tool > demo-output/demo3-partial-build.json && echo "Saved to demo-output/demo3-partial-build.json"
```

What to observe:

- `routing: "PARTIAL_BUILD"` — only missing tables built
- `vault_tables_created` — only WMS tables: hub_stock_movement, lnk_product_location_stock_movement, sat_stock_movement_details
- `existing_tables_reused` — hub_product, hub_location, lnk_product_location, etc. carried over from Demo 1
- `source_tables_extracted` — only `wms.stock_movements`, not erp or procurement tables
- The vault now spans three source systems (ERP + Procurement + WMS) without redundant rebuilds

**New vault additions:**
```
hub_stock_movement ← sat_stock_movement_details
hub_product ← lnk_product_location_stock_movement → hub_location
                                                   → hub_stock_movement
```

---

## Demo 4: Complex Mart — Multi-System Dashboard

A comprehensive question that joins data across all three source systems into a single mart. The vault tables already exist, so only the mart is built.

```bash
curl -s -X POST http://localhost:5678/webhook/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "For each product, show: current stock on hand, reorder point, total units on order from purchase orders, and net stock movements from WMS."}' \
  | python3 -m json.tool > demo-output/demo4-complex-mart.json && echo "Saved to demo-output/demo4-complex-mart.json"
```

What to observe:

- `routing: "PARTIAL_BUILD"` — vault reused, only mart built
- The mart joins hubs, links, and satellites from ERP, Procurement, and WMS
- `mart_sql_plan` — the Dispatcher's structured plan: columns, join_sequence, cte_strategy, aggregations
- `query_code` — shows the full SQL including CTE structure for fan-out prevention
- `output.data` — each product with stock on hand (ERP), reorder point (ERP), PO quantities (Procurement), and net movements (WMS)

---

## Demo 5: QUERY_SOURCE — Source Database Metadata

A metadata question answered directly by the Query Agent without building any vault tables.

```bash
curl -s -X POST http://localhost:5678/webhook/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "How many tables are in the source database?"}' \
  | python3 -m json.tool > demo-output/demo5-query-source.json && echo "Saved to demo-output/demo5-query-source.json"
```

What to observe:

- `routing: "QUERY_SOURCE"` — routed to Query Agent, no vault/mart involved
- `query_code` — the SQL executed against source.duckdb
- Returns source table count across all three schemas (erp, procurement, wms)

---

## Demo 6: Inspect the Vault

Direct queries to examine the Data Vault structure and registries.

Vault registry (shows all vault tables with their types, keys, and relationships):

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT table_name, table_type, pk_column, bk_column, hub_keys, parent_table, parent_key FROM _vault_registry ORDER BY table_type, table_name", "database": "/data/vault.duckdb"}' \
  | python3 -m json.tool > demo-output/demo6-vault-registry.json && echo "Saved to demo-output/demo6-vault-registry.json"
```

Mart registry (shows all marts with what question they answer and their grain):

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT table_name, understood_request, grain, source_vault_tables FROM _mart_registry ORDER BY created_dts", "database": "/data/vault.duckdb"}' \
  | python3 -m json.tool > demo-output/demo6-mart-registry.json && echo "Saved to demo-output/demo6-mart-registry.json"
```

Cross-system join through the vault (product → location → stock movements):

```bash
curl -s -X POST http://localhost:8001/query \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT hp.product_bk, spd.product_name, hl.location_bk, sil.qty_on_hand, spd.reorder_point FROM hub_product hp JOIN sat_product_details spd ON hp.product_hk = spd.product_hk AND spd.load_end_dts IS NULL JOIN lnk_product_location lpl ON hp.product_hk = lpl.product_hk JOIN hub_location hl ON lpl.location_hk = hl.location_hk JOIN sat_inventory_levels sil ON lpl.product_location_hk = sil.product_location_hk AND sil.load_end_dts IS NULL WHERE sil.qty_on_hand < spd.reorder_point LIMIT 10", "database": "/data/vault.duckdb"}' \
  | python3 -m json.tool > demo-output/demo6-vault-query.json && echo "Saved to demo-output/demo6-vault-query.json"
```

---

## Demo 7: MCP Server (Claude Desktop Integration)

Connect Claude Desktop to the pipeline via the Model Context Protocol.

### Configure Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "inventory": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "http://localhost:5678/mcp/inventory-tools/sse"
      ]
    }
  }
}
```

Save and restart Claude Desktop. When the OAuth consent screen appears, click **Allow**.

### Available Tools

| Tool | What it does |
|---|---|
| `ask_inventory_question` | Primary tool — sends a question to the Dispatcher pipeline. Builds vault/mart as needed and returns results with full SQL code |
| `describe_schema` | Lists tables in vault.duckdb (for follow-up exploration only) |
| `run_query` | Runs SQL against vault.duckdb (for follow-up exploration only) |

All source data questions must go through `ask_inventory_question` — the other tools are restricted to vault data for follow-up analysis.

### Example Prompts

Try these in Claude Desktop:

1. **"Which vendors have we spent the most money with? Show top 10 with total spend and number of POs."**
   — Cross-system query joining Procurement purchase orders with vendor details

2. **"Compare each product's unit cost from ERP with the average purchase price from procurement. Which products have the biggest markup?"**
   — Joins ERP product data with Procurement PO line items to calculate price differences

3. **"What is the scrap rate for each product that has work orders? Show the top 10 worst."**
   — Analyzes manufacturing quality using ERP work order data

4. **"How many tables are in the source database?"**
   — Metadata question routed through QUERY_SOURCE path

5. **"For each product, show: current stock on hand, reorder point, total units on order from purchase orders, and net stock movements from WMS."**
   — Complex dashboard joining all three source systems (ERP + Procurement + WMS)

---

## Business Questions Library

Example questions organized by domain. Each builds different vault structures and exercises different routing paths.

### Procurement & Supply Chain

- "Which vendors have we spent the most money with? Show top 10 with total spend and number of POs."
- "What is our total procurement spend by product category? Which categories are most expensive?"
- "Which vendors have the worst delivery performance? Show average lead time and number of late orders."
- "What is the average lead time for purchase orders by vendor?"

### Inventory Optimization

- "Which products are below their reorder point? Include the vendor names that supply each product."
- "For each location, which products are below their reorder point at that specific location?"
- "Which locations are overstocked — where quantity on hand exceeds 3x the reorder point?"
- "What is the total quantity on hand for each location?"

### Manufacturing & Quality

- "What is the scrap rate for each product that has work orders? Show the top 10 worst."
- "Compare planned vs actual production — which work orders had the biggest shortfall between qty_required and qty_stocked?"
- "How many purchase orders are in each status? What is the total dollar amount per status?"

### Cross-System Analytics (2-3 source systems)

- "For each product, show: current stock on hand, reorder point, total units on order from purchase orders, and net stock movements from WMS."
- "Compare each product's unit cost from ERP with the average purchase price from procurement. Which products have the biggest markup?"
- "Which vendors supply the most products that are currently below reorder point?"
- "Give me a complete inventory health dashboard: for each product, show current stock by location, reorder point, safety stock, active PO quantities on order, vendor names and credit ratings, and recent stock movements."

### Warehouse Operations

- "Show total receipts, shipments, and adjustments for each product at each location."
- "Which warehouses have the most stock movement activity?"
- "List all warehouse locations and their capacity."

### Source Metadata

- "How many tables are in the source database?"
- "Which vendors have a credit rating of 1 and are currently active?"
- "How many products do we have in total?"

---

## Architecture Summary

```
User Question
     ↓
Dispatcher Agent (Sonnet — Data Analyst)
     ├── QUERY_ONLY    → Query existing mart → Return results
     ├── QUERY_SOURCE  → Query Agent → Return source metadata
     └── BUILD/PARTIAL → Query Agent (extract source data)
                       → Data Vault Agent (Haiku — generate DDL/load SQL)
                       → Vault DQ Gate (deterministic validation)
                       → Info Mart Agent (Haiku — generate mart SQL from plan)
                       → Mart DQ Gate (deterministic validation)
                       → Query mart → Return results

Data Flow:
  source.duckdb (read-only) → Query Agent → staging tables
  → Data Vault Agent → hub/link/satellite tables in vault.duckdb
  → Info Mart Agent → mart table in vault.duckdb
  → Final SELECT → response with data + query_code
```

---

## Tips

- BUILD_ALL takes 15-30 seconds (multiple LLM calls). QUERY_ONLY is ~5 seconds.
- The `query_code` field in every response contains all SQL as a downloadable text block.
- The `_vault_registry` and `_mart_registry` tables track what's been built and why.
- Mart tables expire after 24h and are rebuilt automatically. Vault tables persist indefinitely.
- If a call fails, check that all agent workflows are active in n8n at `http://localhost:5678`.
