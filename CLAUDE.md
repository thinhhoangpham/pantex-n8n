# Inventory Multi-Agent Pipeline

## Glossary

| Term / Abbreviation | Full Name | Meaning |
|---|---|---|
| n8n | — | An open-source workflow automation tool. Think of it as a visual programming environment where you connect nodes (steps) to build automated processes. Runs at `http://localhost:5678`. |
| API | Application Programming Interface | A way for software systems to communicate with each other over HTTP. We use the n8n REST API to read and update workflows programmatically instead of clicking through the UI. |
| Webhook | — | A URL that listens for incoming HTTP requests. In n8n, each agent workflow is triggered by a webhook — you POST a request to its URL and the workflow runs. |
| LLM | Large Language Model | An AI model that generates text. Here we use Anthropic Claude (Haiku for routing/validation, Sonnet for SQL generation) inside n8n nodes to generate SQL, data models, and validation reports. |
| MCP | Model Context Protocol | An open standard that lets AI agents call external tools (like running a database query) in a structured way. Allows external clients like Claude Desktop to call tools exposed by n8n. |
| DuckDB | — | An open-source analytical database that runs as a single file. Fast, SQL-compatible, no server required. Used here as the storage engine for all source and output data. |
| SQL | Structured Query Language | The standard language for querying and manipulating relational databases. |
| ERP | Enterprise Resource Planning | A software system that manages core business operations — inventory, procurement, manufacturing, finance — in one shared database. Examples: SAP, Oracle PeopleSoft. |
| WMS | Warehouse Management System | Software that tracks physical stock movements — receipts, shipments, adjustments — in warehouses. |
| DV2 | Data Vault 2.0 | A data modeling methodology for enterprise data warehouses. Organizes data into Hubs (business entities), Links (relationships), and Satellites (descriptive attributes). |
| Hub | — | A Data Vault table that stores a unique business entity (e.g. one row per product). Contains only the business key and metadata — no descriptive attributes. |
| Link | — | A Data Vault table that records a relationship between two or more hubs (e.g. which product belongs to which location). |
| Satellite | — | A Data Vault table that stores descriptive attributes for a hub or link, with full history of changes over time. |
| Mart | Information Mart | A business-friendly, pre-aggregated table built from vault data. This is what end users and reports actually query. |
| DDL | Data Definition Language | SQL statements that create or modify database structure (e.g. `CREATE TABLE`, `DROP TABLE`). |
| FastAPI | — | A Python web framework used to build the DuckDB service. Handles incoming HTTP requests and runs SQL against DuckDB. |
| Docker | — | A tool that packages applications into containers — isolated environments that run consistently regardless of the host machine. |
| CSV | Comma-Separated Values | A plain text file format for tabular data. Each line is a row; columns are separated by commas. |
| FK | Foreign Key | A column that references the primary key of another table, linking the two tables together. |

---

## Overview
A multi-agent n8n system that integrates raw inventory data from multiple source systems into downstream information marts using DuckDB. A central dispatcher agent orchestrates specialized sub-agents — Query Agent (data extraction), Data Vault (data modeling), Info Mart (report generation), and Data Quality (validation) — to answer natural language business questions about inventory.

**Source isolation:** Source data lives in read-only `source.duckdb`. All pipeline output (staging, vault, mart tables) goes into `vault.duckdb`. The Dispatcher creates staging tables in `vault.duckdb` by ATTACHing `source.duckdb` (read-only) and copying the needed rows. After the pipeline completes, staging tables are dropped from `vault.duckdb`. This isolates the vault from the source database entirely.

**Source access isolation:** The Query Agent is the only agent that reads source schemas (`erp.*`, `procurement.*`, `wms.*`) directly, always against `source.duckdb`. All other agents work exclusively against `vault.duckdb`.

**Mart expiry:** Mart tables are temporary. The Dispatcher rebuilds a mart if it is older than 24h (TTL), and hard-drops any mart where all rows are older than 48h at the start of every request. Vault tables (hubs, links, satellites) are never expired.

## Current Status
**All agents built and tested for inventory domain. End-to-end pipeline operational. MCP Server live.**

Tests passed:
- Path A (BUILD_ALL): builds vault + mart from scratch with cross-system data (ERP + Procurement)
- Path B (QUERY_ONLY): reuses fresh mart, skips all build agents
- Path C (PARTIAL_BUILD): adds new vault tables incrementally (e.g. WMS on top of existing ERP + Procurement)

Dispatcher response includes: `routing`, `existing_tables_reused`, `source_tables_extracted`, `vault_tables_created`, `timings` (per-agent ms), `generated_sql` (full DDL + load SQL), `dq_status`/`dq_issues`.

DQ gate: when Data Quality checks fail, the Dispatcher returns `status: "error"` with DQ issues instead of querying an empty mart.

**Mart validation + retry:** After mart population, the Dispatcher validates the mart data (checks for empty tables and all-NULL dimension columns). If validation fails, it retries the Info Mart Agent once with explicit error feedback about which JOINs failed, then re-executes. This handles LLM non-determinism in SQL generation.

**Stale mart handling:** When rebuilding a stale mart (24-48h old), the Dispatcher drops the old table first so `CREATE TABLE IF NOT EXISTS` takes effect with the new schema. Mart freshness classification treats `NaT`/invalid timestamps as expired.

**DuckDB compatibility:** Data Vault Agent prompt includes a rule requiring `CAST(col AS VARCHAR)` before `COALESCE(..., '')` in hashdiff calculations, since DuckDB cannot implicitly cast empty strings to numeric types.

**Empty vault table detection:** The Dispatcher inspects row counts for all vault tables (hub_, lnk_, sat_). Tables with 0 rows are classified as empty and flagged for rebuilding. The LLM context shows them under "EMPTY VAULT TABLES" so they get included in `vault_tables_to_create`. The Collect Vault SQL node prepends `DROP TABLE IF EXISTS` before each vault table's DDL to prevent schema mismatch from stale empty tables.

**Mart column awareness:** The Dispatcher fetches column names for fresh mart tables and includes them in the LLM context. The Route Decision prompt requires QUERY_ONLY to verify mart columns cover all dimensions the user asked about — prevents reusing a mart that lacks needed columns (e.g. reusing a product-only mart when the user also asks about vendors).

**Source catalog grain:** Each table in `/data/metadata/source_catalog.json` has a `grain` field describing what one row represents (e.g. `"one row per product per location"`). The Dispatcher prompt instructs the LLM to preserve source grain in the mart — preventing incorrect aggregation across dimensions (e.g. summing inventory across locations when reorder point is checked per location).

**One-to-many fan-out prevention:** The Info Mart Agent prompt (rule 15) requires measures to be calculated in a subquery/CTE first, then joined to one-to-many dimensions (like vendors) afterward. This prevents measure duplication. Enforced by using Sonnet (`claude-sonnet-4-6`) which follows structural SQL instructions — Haiku ignores them.

**Vault hash key naming:** The Data Vault Agent prompt (rule 16) enforces strict naming: hub keys = `<entity>_hk`, link keys = `<entity1>_<entity2>_hk`, satellite parent keys must exactly match the parent hub/link PK name. Prevents hash key mismatches that cause broken joins.

**MCP tool descriptions:** Tool descriptions instruct Claude Desktop to always use `ask_inventory_question` first (which calls the Dispatcher). `run_query` and `describe_schema` are for follow-up analysis only, not for investigating empty tables or building data.

MCP Server (Step 8) complete. SSE endpoint: `http://localhost:5678/mcp/inventory-tools/sse`

---

## Infrastructure

- **n8n** — Workflow automation engine at `http://localhost:5678`
- **n8n API** — REST API at `http://localhost:5678/api/v1`. Requires header `X-N8N-API-KEY`. Used to read and update workflows programmatically.
- **duckdb-service** — A small Python (FastAPI) web server that accepts SQL over HTTP and runs it against DuckDB files. Runs at `http://localhost:8001` (or `http://duckdb-service:8001` when called from inside Docker containers).
  - `POST /query` — run a single SQL query: `{"sql": "SELECT ...", "database": "/data/source.duckdb"}`
  - `POST /execute-batch` — run a list of SQL statements in sequence: `{"statements": ["CREATE TABLE ...", "INSERT ..."], "database": "/data/vault.duckdb"}`
  - `GET /health` — returns `{"status": "ok"}` if service is running
- **source.duckdb** — read-only source data at `/data/source.duckdb`. Contains raw ERP, procurement, and WMS data in named schemas (erp, procurement, wms). Never modified by the pipeline.
- **vault.duckdb** — pipeline output at `/data/vault.duckdb`. Contains hub/link/satellite/mart tables (all in the main schema), plus temporary staging tables (`stg_*`) during active pipeline runs.

---

## Source Data
Three schemas in `source.duckdb` simulating separate upstream systems. Full documentation in `data/SOURCE_DATA.md`.

| Schema | Simulates | Key Tables |
|---|---|---|
| `erp` | ERP system — products, stock, work orders | products, inventory_levels, locations, work_orders |
| `procurement` | Procurement system — buying and suppliers | vendors, purchase_orders, po_lines |
| `wms` | Warehouse Management System — stock movements | warehouses, stock_movements |

**Data source:** Microsoft AdventureWorks (MIT license) for `erp` and `procurement`. Synthetic for `wms`.

---

## n8n Workflows

All workflows are managed via the n8n REST API. Workflow JSON can be fetched and updated with `GET/PUT /api/v1/workflows/{id}`.

| Workflow | ID | Active | Webhook Path | Purpose |
|---|---|---|---|---|
| Dispatcher Agent | `EPobOCC4V3tBomcw` | true | `webhook/dispatcher` | Entry point — receives user question, orchestrates all other agents in sequence. LLM: Haiku. |
| Query Agent | `OGfd8tWVC96yFoeD` | true | `webhook/query-agent` | Reads source schemas and extracts data as JSON rows. The only agent that touches source schemas directly. LLM: Haiku. |
| Data Vault Agent | `26bHrzBpfG5WS12G` | true | `webhook/data-vault-agent` | Generates Data Vault 2.0 DDL and load SQL. Reads from stg_* staging tables only. LLM: **Sonnet** (`claude-sonnet-4-6`). |
| Info Mart Agent | `WckXx5XegNLPPAk0` | true | `webhook/info-mart-agent` | Generates mart table DDL and populate SQL. LLM: **Sonnet** (`claude-sonnet-4-6`). |
| Data Quality Agent | `jzJTeQJm039WMLU6` | true | `webhook/data-quality-agent` | Validates generated DDL against naming and structural rules. LLM: Haiku. |
| MCP Server | `pENYT8gz5IR7zUan` | true | `mcp/inventory-tools/sse` (SSE) | Exposes run_query, describe_schema, ask_inventory_question tools via MCP for external AI agents |

---

## Key Files

| File | Purpose |
|---|---|
| `data/SOURCE_DATA.md` | Full documentation of source schemas, tables, columns, and data origin |
| `data/source.duckdb` | Read-only source database — erp, procurement, and wms schemas |
| `data/vault.duckdb` | Pipeline output database — hub/link/satellite/mart tables and temporary staging tables |
| `data/source-files/aw_*.csv` | Raw AdventureWorks CSV files used to seed source.duckdb |
| `/data/metadata/source_catalog.json` | Source catalog with table schemas, primary keys, foreign keys, and grain (what one row represents). Read by the Dispatcher at runtime. Lives inside the n8n container. |
| `docker-compose.yml` | Defines and configures the n8n and duckdb-service Docker containers |
| `duckdb-service/main.py` | Source code for the DuckDB HTTP service |
| `IMPLEMENTATION_PLAN.md` | Step-by-step plan for rebuilding agents for inventory domain |
| `DEMO.md` | Demo guide with copy-pasteable commands for all three routing paths |
| `workflows/*.json` | Workflow JSON files for all agents (Dispatcher, Query, Data Vault, Info Mart, Data Quality, MCP Server) |

---

## Running Services

```bash
# Start both containers (n8n and duckdb-service)
docker compose up -d

# Check duckdb-service is healthy
curl http://localhost:8001/health

# Check running containers
docker compose ps
```

---

## Next Steps
All steps complete. MCP Server is live at `http://localhost:5678/mcp/inventory-tools/sse`.
