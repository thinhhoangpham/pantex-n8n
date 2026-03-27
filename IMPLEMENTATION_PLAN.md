# Inventory Multi-Agent Pipeline — Implementation Plan

## Context

Build a multi-agent orchestration system in n8n that integrates raw inventory data from three source systems (ERP, Procurement, WMS) into a Data Vault 2.0 data model and business-friendly information marts using DuckDB. The system uses a smart Dispatcher that decides which agents to call based on what already exists — avoiding unnecessary rebuilds.

---

## Progress

| Step | Task | Status |
|---|---|---|
| — | Source data: download AdventureWorks CSVs and load into `source.duckdb` (3 schemas, 9 tables) | DONE |
| — | Source data: documentation (`data/SOURCE_DATA.md`) | DONE |
| — | Remove all PMIS artifacts (parquet files, metadata, prompts, docs) | DONE |
| — | Separate into two databases: source data in `source.duckdb` (read-only), pipeline output in `vault.duckdb` | DONE |
| — | Update `CLAUDE.md` and `SOURCE_DATA.md` with glossaries and plain-English explanations | DONE |
| 1 | Create metadata files (`source_catalog.json`, `dv2_rules.json`) | DONE |
| 2 | Build Query Agent (full rebuild of archived stub) | DONE |
| 3 | Build Data Vault Agent (inventory domain prompts) | DONE |
| 4 | Build Info Mart Agent (inventory domain prompts) | DONE |
| 5 | Build Data Quality Agent (inventory domain checks) | DONE |
| 6 | Build Dispatcher Agent (smart routing, orchestration) | DONE |
| 7 | End-to-end testing | DONE |
| 7a | Fix: DV2 modeling — one hub per entity, proper hash key naming | DONE |
| 7b | Fix: maxTokensToSample 4096→16384 on all agents, robust JSON parser for code-fenced/truncated LLM output | DONE |
| 7c | Fix: DQ gate in Dispatcher — DQ failures return error response instead of querying empty mart | DONE |
| 8 | Create MCP Server workflow | DONE |

---

## Architecture

### Agents

| Agent | Purpose | Databases |
|---|---|---|
| **Dispatcher** | Receives user question, inspects what vault/mart tables already exist, decides which agents to call and in what order | Calls Query Agent to inspect the database |
| **Query Agent** | Generates SQL (via LLM) and runs it against the appropriate database. Used for inspecting schemas, extracting source data as JSON rows, and returning final results to the user. **This is the only agent that reads source schemas directly.** | `/data/source.duckdb` for source queries; `/data/vault.duckdb` for vault/mart queries |
| **Data Vault Agent** | Generates DDL (CREATE TABLE) and load SQL (INSERT...SELECT) to build hub, link, and satellite tables. **Reads only from staging tables (`stg_*`), never from source schemas directly.** | Reads from `stg_*` staging tables in `vault.duckdb`, writes vault tables to main schema of `vault.duckdb` |
| **Info Mart Agent** | Generates DDL and populate SQL to build business-friendly report tables (marts) from vault tables | Reads vault tables from `vault.duckdb` main schema, writes mart tables to `vault.duckdb` main schema |
| **Data Quality Agent** | Validates generated DDL against naming conventions, structural rules, and referential integrity | Reads vault/mart tables from `vault.duckdb` |

### Two Databases

| Database | Path | Contents |
|---|---|---|
| `source.duckdb` | `/data/source.duckdb` | Read-only. Raw ERP source tables (`erp.*`), procurement source tables (`procurement.*`), and WMS source tables (`wms.*`). Never modified by the pipeline. |
| `vault.duckdb` | `/data/vault.duckdb` | Writable pipeline output. Hub/link/satellite tables (`hub_*`, `lnk_*`, `sat_*`), mart tables (`mart_*`), and temporary staging tables (`stg_*`) during pipeline runs. All in the `main` schema (no prefix). Grows incrementally as users ask new questions. |

### Staging Layer

Before the Data Vault Agent runs, source data is copied into staging tables in `vault.duckdb`. The Dispatcher does this by ATTACHing `source.duckdb` as read-only, running `CREATE TABLE stg_erp_products AS SELECT * FROM source_db.erp.products`, then DETACHing. This decouples the Data Vault Agent from source schemas entirely.

**Staging table naming:** `stg_<schema>_<table>` — e.g., `stg_erp_products`, `stg_procurement_vendors`, `stg_wms_stock_movements`

**Lifecycle:**
1. **Created** by the Dispatcher in `vault.duckdb` using ATTACH/DETACH: `ATTACH '/data/source.duckdb' AS source_db (READ_ONLY); CREATE TABLE stg_erp_products AS SELECT * FROM source_db.erp.products; DETACH source_db`.
2. **Read** by the Data Vault Agent's generated load SQL — never `erp.*`, `procurement.*`, or `wms.*`.
3. **Dropped** from `vault.duckdb` by the Dispatcher at the end of the pipeline run (after all vault and mart SQL has been executed).

---

## Smart Dispatcher — Three Routing Paths

The Dispatcher does NOT blindly run all agents every time. It first calls the Query Agent to check what vault/mart tables already exist in the main schema of `vault.duckdb`, then picks the shortest path.

### Path A — First-Time Question (nothing exists)

When a user asks a question and no relevant vault or mart tables exist yet.

```
User: "What products are below reorder point?"

Dispatcher
  │
  ├─ 1. Query Agent      → SHOW TABLES (main schema of vault.duckdb) → empty
  │
  ├─ 2. Query Agent      → extract source data from erp.products, erp.inventory_levels
  │                         → returns JSON rows
  │
  ├─ 3. Dispatcher       → HTTP Request to duckdb-service (vault.duckdb): ATTACH source.duckdb, CREATE TABLE stg_erp_products AS ...,
  │                         CREATE TABLE stg_erp_inventory_levels AS ..., DETACH source.duckdb
  │
  ├─ 4. Data Vault Agent → generates DDL + load SQL for:
  │                         hub_product, hub_location,
  │                         lnk_product_location, sat_inventory_balance
  │                         (load SQL reads from stg_erp_products, stg_erp_inventory_levels)
  │
  ├─ 5. Dispatcher       → HTTP Request to duckdb-service: runs vault DDL + INSERT into vault.duckdb (main schema)
  │
  ├─ 6. Info Mart Agent  → generates mart_low_stock DDL + populate SQL
  │
  ├─ 7. Dispatcher       → HTTP Request to duckdb-service (vault.duckdb): runs mart SQL + DROP TABLE stg_erp_* (cleanup staging)
  │
  ├─ 8. DQ Agent         → validates naming, structure, referential integrity
  │
  └─ 9. Query Agent      → SELECT * FROM mart_low_stock → return results
```

### Path B — Repeat Question (mart already exists)

When the user asks a question and a matching mart table is already built.

```
User: "What products are below reorder point?"

Dispatcher
  │
  ├─ 1. Query Agent   → SHOW TABLES (main schema of vault.duckdb)
  │                      → finds mart_low_stock ✓
  │
  └─ 2. Query Agent   → SELECT * FROM mart_low_stock → return results
```

**Skips all build agents — instant response.**

### Path C — Partial Rebuild (vault exists but needs more data)

When the user asks a question that requires data not yet in the vault.

```
User: "Show me low stock products with their vendor delivery history"

Dispatcher
  │
  ├─ 1. Query Agent      → SHOW TABLES (main schema of vault.duckdb)
  │                         → finds hub_product, sat_inventory_balance ✓
  │                         → but NO hub_vendor, no vendor data ✗
  │
  ├─ 2. Query Agent      → extract vendor data from procurement.vendors, procurement.po_lines
  │                         → returns JSON rows
  │
  ├─ 3. Dispatcher       → HTTP Request to duckdb-service (vault.duckdb): ATTACH source.duckdb, CREATE TABLE stg_procurement_vendors AS ...,
  │                         CREATE TABLE stg_procurement_po_lines AS ..., DETACH source.duckdb
  │
  ├─ 4. Data Vault Agent → generates ONLY the missing pieces:
  │                          hub_vendor, lnk_product_vendor, sat_vendor_profile
  │                          (load SQL reads from stg_procurement_vendors, stg_procurement_po_lines)
  │
  ├─ 5. Dispatcher       → HTTP Request to duckdb-service: runs only the new DDL + load SQL against vault.duckdb
  │
  ├─ 6. Info Mart Agent  → generates mart_low_stock_with_vendor_delivery
  │
  ├─ 7. Dispatcher       → HTTP Request to duckdb-service (vault.duckdb): runs mart SQL + DROP TABLE stg_procurement_* (cleanup staging)
  │
  ├─ 8. DQ Agent         → validates
  │
  └─ 9. Query Agent      → query the new mart → return results
```

**Only builds what's missing — doesn't rebuild from scratch.**

---

## Mart Expiry Strategy

Marts are temporary by design — they are pre-aggregated snapshots of vault data, and source data (inventory levels, stock movements, POs) changes throughout the day. A mart that was built hours ago may return stale results.

### TTL Rules

| Threshold | Behavior |
|---|---|
| `mart_insert_dts` < 24h old | Mart is fresh — use QUERY_ONLY path |
| `mart_insert_dts` 24–48h old | Mart is stale — drop and rebuild mart only (vault tables are still current) |
| `mart_insert_dts` > 48h old | Hard cleanup — mart is dropped automatically at the start of the next Dispatcher request |

**No count cap.** Time-based expiry handles cleanup naturally without capping how many marts can coexist.

### Integration with Routing

The TTL check happens before the LLM makes its routing decision:

1. **Cleanup step (always runs):** At the start of every Dispatcher request, identify any mart tables where all rows have `mart_insert_dts` older than 48h. Drop those tables via the Execution Agent before the LLM sees the table list.
2. **Freshness check (informs LLM):** For marts that survive cleanup (24–48h old), the Dispatcher passes their age to the LLM. The LLM treats a stale mart as absent — it triggers a mart-only rebuild rather than QUERY_ONLY.
3. **Vault tables are not expired:** Hub, link, and satellite tables are never dropped by this mechanism. Only marts expire.

### Dispatcher Node Flow (updated)

```
Webhook
  → Read File (source_catalog.json)
  → Code (parse catalog)
  → HTTP Request (Query Agent: list existing vault/mart tables with mart_insert_dts)
  → Code (classify: identify marts >48h for hard drop, flag marts 24-48h as stale)
  → HTTP Request (duckdb-service: DROP marts >48h) [conditional — only if stale marts found]
  → Code (combine: user request + catalog + existing tables + mart freshness status)
  → LLM (decides routing, aware of mart freshness)
  → ... rest of flow
```

### Routing Paths with TTL

**Path B (QUERY_ONLY)** — only taken if mart exists AND `mart_insert_dts` < 24h old.

**Path C (PARTIAL_BUILD)** — taken when:
- Mart exists but is 24–48h old: Dispatcher skips vault rebuild, regenerates mart only.
- Vault tables exist but no mart (or mart was dropped by hard cleanup): build mart only.
- Vault tables are partially missing: build missing vault tables + mart.

**Path A (BUILD_ALL)** — vault is empty or was never built for this question.

---

## Dispatcher Logic (LLM Decision-Making)

The Dispatcher's LLM receives four inputs:
1. The user's natural language question
2. The list of existing vault and mart tables (from Query Agent inspection), with mart freshness status
3. The source schema catalog (from a metadata file)
4. Mart freshness classification (fresh <24h / stale 24–48h / already dropped >48h)

It outputs a JSON task plan:

```json
{
  "understood_request": "Find products where qty_on_hand < reorder_point",
  "routing_decision": "BUILD_ALL | QUERY_ONLY | PARTIAL_BUILD",
  "existing_tables_to_reuse": ["hub_product", "sat_inventory_balance"],
  "missing_data": ["vendor delivery history"],
  "source_schemas_needed": ["erp", "procurement"],
  "vault_tables_to_create": ["hub_vendor", "lnk_product_vendor", "sat_vendor_profile"],
  "mart_table_name": "mart_low_stock_with_vendor",
  "business_keys": ["product_id", "vendor_id"],
  "grain": "one row per product per vendor",
  "metrics": ["qty_on_hand", "reorder_point", "avg_delivery_days"],
  "final_query": "SELECT * FROM mart_low_stock_with_vendor ORDER BY qty_on_hand ASC"
}
```

The Dispatcher then follows the routing_decision to call the right agents in the right order.

---

## Workflow Implementation

### n8n Workflow IDs

| Workflow | n8n ID | Status |
|---|---|---|
| Dispatcher Agent | `EPobOCC4V3tBomcw` | DONE — active, webhook/dispatcher |
| Query Agent | `OGfd8tWVC96yFoeD` | DONE — active, webhook/query-agent |
| Data Vault Agent | `26bHrzBpfG5WS12G` | DONE — active, webhook/data-vault-agent |
| Info Mart Agent | `WckXx5XegNLPPAk0` | DONE — active, webhook/info-mart-agent |
| Data Quality Agent | `jzJTeQJm039WMLU6` | DONE — active, webhook/data-quality-agent |
| MCP Server | `pENYT8gz5IR7zUan` | DONE — active, mcp/inventory-tools/sse |

All workflows are edited via the n8n REST API at `http://localhost:5678/api/v1`.

---

### Step 1 — Create Metadata Files

Create two metadata files that agents read as context.

#### `data/metadata/source_catalog.json`
Describes the source schemas so agents know what tables and columns are available.

```json
{
  "source_systems": [
    {
      "system": "ERP",
      "description": "Enterprise Resource Planning — product master data, stock levels, production work orders",
      "schema": "erp",
      "database": "/data/source.duckdb",
      "tables": ["products", "inventory_levels", "locations", "work_orders"]
    },
    {
      "system": "Procurement",
      "description": "Procurement system — vendors, purchase orders, delivery tracking",
      "schema": "procurement",
      "database": "/data/source.duckdb",
      "tables": ["vendors", "purchase_orders", "po_lines"]
    },
    {
      "system": "WMS",
      "description": "Warehouse Management System — warehouse locations and stock movements",
      "schema": "wms",
      "database": "/data/source.duckdb",
      "tables": ["warehouses", "stock_movements"]
    }
  ]
}
```

#### `data/metadata/dv2_rules.json`
Rules for Data Vault 2.0 modeling that the Data Vault Agent and DQ Agent use.

```json
{
  "hub_prefix": "hub_",
  "link_prefix": "lnk_",
  "satellite_prefix": "sat_",
  "mart_prefix": "mart_",
  "hash_algorithm": "MD5",
  "hash_key_suffix": "_hk",
  "business_key_suffix": "_bk",
  "required_hub_columns": ["load_dts TIMESTAMP", "record_source VARCHAR(100)"],
  "required_satellite_columns": ["load_dts TIMESTAMP", "load_end_dts TIMESTAMP", "record_source VARCHAR(100)", "hashdiff VARCHAR(32)"],
  "record_source_values": ["SOURCE_ERP", "SOURCE_PROCUREMENT", "SOURCE_WMS"],
  "mart_audit_column": "mart_insert_dts TIMESTAMP DEFAULT CURRENT_TIMESTAMP",
  "naming_convention": "snake_case",
  "database": "/data/source.duckdb"
}
```

---

### Step 2 — Build Query Agent (`OGfd8tWVC96yFoeD`)

Full rebuild. This agent is called multiple times per request. It has three distinct roles:
1. **Schema inspection** — list existing vault/mart tables, check mart freshness
2. **Source data extraction** — SELECT from source schemas (`erp.*`, `procurement.*`, `wms.*`) and return JSON rows to the Dispatcher. This is the only place in the pipeline where source schemas are read.
3. **Final result queries** — SELECT from mart tables and return results to the user

**Webhook path:** `webhook/query-agent`

**Node flow:**
```
Webhook → LLM → Code (parse) → HTTP Request (run query) → Code (format) → Respond to Webhook
```

**LLM system prompt:**
```
You are a Query Agent for an inventory data system.
You have access to two DuckDB databases:
- /data/source.duckdb — read-only, source tables in named schemas (erp, procurement, wms)
- /data/vault.duckdb — vault and mart tables in the main schema (no prefix)

The database path is provided in the request body — use it exactly as-is.

Given a task (inspect schema, extract data, or query results), generate a DuckDB SQL query.

Rules:
- Always qualify source table names with schema: erp.products, procurement.vendors, etc.
- Vault/mart tables use no schema prefix: hub_product, mart_low_stock, etc.
- For schema inspection: use SHOW TABLES or DESCRIBE
- For data extraction: add LIMIT 20 unless told otherwise
- For final results: return the full query the user needs

Respond ONLY with JSON:
{
  "sql": "SELECT ...",
  "explanation": "what this query does"
}
```

**Input body receives:** `{"task": "...", "database": "/data/source.duckdb OR /data/vault.duckdb", "context": "..."}`

**HTTP Request node:** POST `http://duckdb-service:8001/query` with `{"sql": "...", "database": "..."}`
- Uses the database path from the request body — source queries go to `/data/source.duckdb`, vault/mart queries go to `/data/vault.duckdb`.

**Output:** `{"status": "success", "output": {"data": [...], "sql": "...", "explanation": "..."}}`

---

### Step 3 — Update Dispatcher Agent (`s893QlcroZnodqhb`)

This is the most complex workflow — it orchestrates everything.

**Webhook path:** `webhook-test/dispatcher` (test mode during development)

**Node flow:**
```
Webhook
  → Read File (source_catalog.json)
  → Code (parse catalog)
  → HTTP Request (Query Agent: list existing vault/mart tables from vault.duckdb with mart_insert_dts)
  → Code (cleanup: identify marts >48h for hard drop, classify marts 24-48h as stale)
  → HTTP Request (duckdb-service vault.duckdb: DROP marts >48h) [conditional — only if any found]
  → Code (combine: user request + catalog + existing tables + mart freshness status)
  → LLM (decides routing: BUILD_ALL / QUERY_ONLY / PARTIAL_BUILD)
  → Code (parse task plan)
  → [Conditional branching based on routing_decision]
     ├─ QUERY_ONLY: (only reached if mart_insert_dts < 24h)
     │    → HTTP Request (Query Agent: run final query on vault.duckdb)
     │    → Respond to Webhook
     │
     ├─ BUILD_ALL or PARTIAL_BUILD:
     │    → HTTP Request (Query Agent: extract source data from source.duckdb → JSON rows)
     │    → HTTP Request (duckdb-service vault.duckdb: ATTACH source.duckdb, CREATE stg_* tables, DETACH)
     │    → HTTP Request (Data Vault Agent)  [skipped if PARTIAL_BUILD and vault is current]
     │    → HTTP Request (duckdb-service vault.duckdb: run vault DDL + load SQL — reads stg_* tables)  [skipped if above skipped]
     │    → HTTP Request (Info Mart Agent)
     │    → HTTP Request (duckdb-service vault.duckdb: run mart DDL + load + DROP stg_* tables)
     │    → HTTP Request (DQ Agent)
     │    → HTTP Request (Query Agent: run final query on vault.duckdb)
     │    → Respond to Webhook
```

**Cleanup SQL logic (Code node):**

The cleanup Code node runs the following logic against the mart freshness data returned by the Query Agent:
```sql
-- Query to get mart tables and their oldest mart_insert_dts
SELECT table_name, MIN(mart_insert_dts) AS oldest_row
FROM information_schema.tables
-- (executed per mart table via Query Agent)

-- Drop condition
WHERE oldest_row < NOW() - INTERVAL 48 HOURS
```

Any mart table where all rows are older than 48h is sent to duckdb-service as a `DROP TABLE` statement via HTTP Request. Mart tables with rows in the 24–48h window are flagged as `stale` in the context passed to the LLM.

**LLM system prompt:**
```
You are a Dispatcher for an inventory data integration system.

You receive:
1. A user's natural language question about inventory
2. A catalog of available source systems (ERP, Procurement, WMS)
3. A list of tables that already exist in the vault database

Your job: decide the fastest way to answer the question.

ROUTING RULES:
- If a mart table already exists AND mart_insert_dts < 24h old → QUERY_ONLY
- If a mart table exists but mart_insert_dts is 24–48h old (stale) → PARTIAL_BUILD (rebuild mart only, vault tables are still current)
- If vault hub/sat tables exist but no mart for this question → PARTIAL_BUILD (build mart only)
- If the vault is missing hub/sat tables needed → PARTIAL_BUILD (build missing vault + mart)
- If the vault is empty → BUILD_ALL

Note: marts older than 48h are dropped before you run, so you will not see them in the table list.

Respond ONLY with JSON:
{
  "understood_request": "...",
  "routing_decision": "BUILD_ALL" | "QUERY_ONLY" | "PARTIAL_BUILD",
  "existing_tables_to_reuse": [],
  "missing_data": [],
  "source_schemas_needed": [],
  "vault_tables_to_create": [],
  "mart_table_name": "mart_...",
  "business_keys": [],
  "grain": "...",
  "metrics": [],
  "final_query": "SELECT ... FROM mart_..."
}
```

---

### Step 4 — Update Data Vault Agent (`26bHrzBpfG5WS12G`)

**Webhook path:** `webhook/data-vault-agent` (unchanged)

**Node flow:** Same structure — Webhook → Read File → Code (Merge Context) → LLM → Code (Parse Output) → Respond

**Key design constraint:** The Data Vault Agent must NEVER reference source schemas directly (`erp.*`, `procurement.*`, `wms.*`). All load SQL reads from `stg_*` staging tables that the Dispatcher created in `vault.duckdb` (via ATTACH/DETACH from `source.duckdb`) prior to this agent being called. All DDL and load SQL targets `vault.duckdb`.

**Key prompt changes:**
- Input field renamed from `source_schema` to `staging_tables` — describes the staging tables available, not the source schemas
- Load SQL uses `SELECT FROM stg_erp_products`, `stg_procurement_vendors`, etc.
- Record source values: 'SOURCE_ERP', 'SOURCE_PROCUREMENT', 'SOURCE_WMS'
- Must accept a list of specific tables to create (from Dispatcher) rather than always creating everything
- Read File points to `/data/metadata/dv2_rules.json`

**Receives from Dispatcher:**
```json
{
  "staging_tables": [
    {
      "name": "stg_erp_products",
      "original_source": "erp.products",
      "columns": [
        {"name": "product_id", "type": "VARCHAR"},
        {"name": "product_name", "type": "VARCHAR"},
        {"name": "sku", "type": "VARCHAR"},
        {"name": "unit_cost", "type": "DECIMAL(12,2)"},
        {"name": "list_price", "type": "DECIMAL(12,2)"},
        {"name": "safety_stock", "type": "INTEGER"},
        {"name": "reorder_point", "type": "INTEGER"}
      ]
    }
  ],
  "vault_tables_to_create": ["hub_product", "hub_location", "sat_inventory_balance"],
  "existing_vault_tables": ["hub_vendor"],
  "business_keys": ["product_id", "location_id"]
}
```

**Returns:** `{"vault_tables": [{"table_name": "...", "table_type": "HUB|LINK|SATELLITE", "ddl": "...", "load_sql": "..."}]}`

**Verification:** Confirm that all `load_sql` values reference `stg_*` tables, not `erp.*`, `procurement.*`, or `wms.*`.

---

### Step 5 — Update Info Mart Agent (`vQu9DlE314ibXRfx`)

**Webhook path:** `webhook/info-mart-agent` (unchanged)

**Key prompt changes:**
- Mart naming: `mart_` prefix
- No hash keys (_hk) or DV2 technical columns exposed in mart
- Dimension columns use `_bk` suffix from business keys
- Audit column: `mart_insert_dts TIMESTAMP DEFAULT CURRENT_TIMESTAMP`
- Filter current satellite records: `WHERE load_end_dts IS NULL`
- Receives the list of available vault tables (so it knows what it can join)

**Receives from Dispatcher:**
```json
{
  "vault_tables": [...],
  "mart_table_name": "mart_low_stock",
  "grain": "one row per product per location",
  "metrics": ["qty_on_hand", "reorder_point", "shortfall"],
  "business_keys": ["product_id", "location_id"]
}
```

**Returns:** `{"mart_table": {"table_name": "...", "ddl": "...", "populate_sql": "...", "view_sql": "..."}}`

---

### Step 6 — Update Data Quality Agent (`cfTkrDuSIwREt5qJ`)

**Webhook path:** `webhook/data-quality-agent` (unchanged)
**LLM model:** Claude Sonnet 4.6 (more capable, kept from before)

**Check categories:**
- **NAMING** — hub_/lnk_/sat_/mart_ prefixes, snake_case, no hash keys in mart
- **STRUCTURAL** — hubs have load_dts + record_source, satellites have hashdiff, links have parent hash keys
- **REFERENTIAL** — satellite parent keys reference existing hubs/links, mart JOINs match vault PKs
- **DATA LOGIC** — aggregations match stated grain, no technical DV2 columns in mart

**Read File:** points to `/data/metadata/dv2_rules.json`

---

### Step 7 — Create MCP Server Workflow (new)

A new workflow that exposes inventory query capabilities to external AI agents (e.g. Claude Desktop) via the Model Context Protocol (MCP).

**Workflow ID:** `pENYT8gz5IR7zUan`

**MCP SSE URL:** `http://localhost:5678/mcp/inventory-tools/sse`

**Node types used:**
- `@n8n/n8n-nodes-langchain.mcpTrigger` — MCP Server Trigger, path: `inventory-tools`
- `@n8n/n8n-nodes-langchain.toolHttpRequest` — HTTP Request tool nodes for `run_query` and `describe_schema`
- `@n8n/n8n-nodes-langchain.toolCode` — Code tool node for `ask_inventory_question`

**Three tools exposed:**

| Tool | Node type | What it does |
|---|---|---|
| `run_query` | `toolHttpRequest` | Runs a SQL statement against source.duckdb or vault.duckdb via the duckdb-service `POST /query` endpoint |
| `describe_schema` | `toolHttpRequest` | Lists tables in source.duckdb or vault.duckdb using `SHOW TABLES` via the duckdb-service |
| `ask_inventory_question` | `toolCode` | Sends a natural language question to the Dispatcher via `POST http://n8n:5678/webhook/dispatcher` and returns the full pipeline response |

**Claude Desktop configuration:**

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "inventory": {
      "url": "http://localhost:5678/mcp/inventory-tools/sse"
    }
  }
}
```

Restart Claude Desktop after saving. The three tools will appear in the tool picker.

---

## Implementation Order

```
Step 1: Create metadata files (source_catalog.json, dv2_rules.json)
Step 2: Build Query Agent (full rebuild)
Step 3: Update Dispatcher Agent (smart routing)
Step 4: Update Data Vault Agent (inventory prompts)
Step 5: Update Info Mart Agent (inventory prompts)
Step 6: Update Data Quality Agent (inventory checks)
Step 7: Create MCP Server workflow
```

Steps 4, 5, 6 can run in parallel once the Dispatcher (step 3) is done.

---

## Verification

### Test 1 — Query Agent (direct call)
```bash
curl -X POST http://localhost:5678/webhook/query-agent \
  -H "Content-Type: application/json" \
  -d '{"task": "List all tables", "database": "/data/source.duckdb"}'
```
Expected: returns list of erp/procurement/wms tables.

### Test 2 — Dispatcher Path A (first-time, full build)
```bash
curl -X POST http://localhost:5678/webhook-test/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "What products are below reorder point?"}'
```
Expected: builds vault + mart, returns results from mart_low_stock.

### Test 3 — Dispatcher Path B (repeat query)
Run the same curl again. Expected: skips build, queries existing mart directly.

### Test 4 — Dispatcher Path C (partial build)
```bash
curl -X POST http://localhost:5678/webhook-test/dispatcher \
  -H "Content-Type: application/json" \
  -d '{"user_request": "Show low stock products with vendor delivery performance"}'
```
Expected: reuses hub_product + sat_inventory_balance, builds hub_vendor + new mart.

### Test 5 — MCP Server
Connect Claude Desktop to `http://localhost:5678/mcp/inventory-tools/sse` and ask it to run an inventory query.

---

## Future Work
- **Human error detection:** duplicate transactions, negative quantities, cross-system qty mismatches, orphaned references
- **Webhook authentication:** API key headers on all sub-agent webhooks
- **Refresh mechanism:** way to force-rebuild vault/mart when source data changes
- **History tracking:** keep old mart versions instead of overwriting
