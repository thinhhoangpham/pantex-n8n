# Source Data Reference

## Glossary

| Term / Abbreviation | Full Name | Meaning |
|---|---|---|
| ERP | Enterprise Resource Planning | A software system companies use to manage core operations (inventory, procurement, finance, HR) in one shared database. Examples: SAP, Oracle PeopleSoft, Microsoft Dynamics. |
| WMS | Warehouse Management System | Software that controls day-to-day warehouse operations — where items are stored, how they move, what is received and shipped. Examples: Manhattan Associates, Blue Yonder. |
| PO | Purchase Order | A formal document a company sends to a supplier to request goods at an agreed price and quantity. |
| SKU | Stock Keeping Unit | A unique code assigned to each distinct product to track it in inventory. |
| FK | Foreign Key | A column in one table that references the primary key of another table, creating a link between them. |
| OLTP | Online Transaction Processing | A type of database designed for recording individual business transactions in real time (sales, orders, receipts), as opposed to analytics. |
| CSV | Comma-Separated Values | A plain text file format where each row is a record and columns are separated by commas. Simple and universally supported. |
| MIT License | Massachusetts Institute of Technology License | A permissive open-source software license that allows free use, modification, and distribution with minimal restrictions. |
| DuckDB | — | An open-source analytical database that runs as a single file. Very fast for SQL queries. Used here as the storage engine for all source and output data. |
| SQL | Structured Query Language | The standard language for querying and manipulating relational databases. |
| VARCHAR | Variable Character | A data type for text of variable length. |
| DECIMAL | — | A data type for exact numeric values with decimal places (e.g. prices, costs). |
| INTEGER | — | A data type for whole numbers (no decimal places). |
| BOOLEAN | — | A data type with only two possible values: true or false. |

---

## Overview

The source layer simulates a company running three separate operational systems that do not natively communicate with each other. Data is stored in `/data/source.duckdb` across three schemas (logical groupings of tables within the database). This multi-source setup represents a common real-world problem: the same company's inventory data is split across an ERP, a procurement system, and a WMS — and integrating them requires a dedicated data pipeline.

---

## Data Source: AdventureWorks

**What it is:** A sample database published by Microsoft representing a fictional bicycle manufacturer called Adventure Works Cycles. It is widely used in data engineering practice because it has realistic, normalized, relational data — meaning the tables are structured the way a real business database would be, with proper relationships between them.

**License:** MIT (free to use for any purpose)
**Original source:** https://github.com/Microsoft/sql-server-samples
**CSV files downloaded from:** https://github.com/olafusimichael/AdventureWorksCSV
**Local copies saved to:** `/data/source-files/aw_*.csv`

The `erp` and `procurement` schemas use AdventureWorks data with columns renamed to match generic inventory naming conventions. The `wms` schema is fully synthetic (generated) because AdventureWorks does not include warehouse movement data.

---

## Schema: `erp`

Simulates the company's **ERP system** (Enterprise Resource Planning — the master system for products, stock, and production). This is the source of truth for what products exist, how many are in stock, and what is being manufactured.

---

### `erp.products` — 504 rows
The product master catalog. Every item the company manufactures, sells, or stocks has one row here. Think of it as the company's official list of everything it sells.

| Column | Type | Description |
|---|---|---|
| `product_id` | VARCHAR | Unique identifier for the product (e.g. "707") |
| `product_name` | VARCHAR | Full descriptive name (e.g. "Sport-100 Helmet, Red") |
| `sku` | VARCHAR | Stock Keeping Unit code — a short code used in day-to-day operations (e.g. "HL-U509-R") |
| `unit_cost` | DECIMAL(12,2) | How much it costs the company to manufacture this product (in dollars) |
| `list_price` | DECIMAL(12,2) | The price the company charges customers (in dollars) |
| `safety_stock` | INTEGER | The minimum quantity that must always be on hand before triggering a restock alert |
| `reorder_point` | INTEGER | The stock level at which a new production or purchase order should be created |
| `product_line` | VARCHAR | Which product family it belongs to: R=Road bikes, M=Mountain bikes, T=Touring bikes, S=Standard/other |
| `product_class` | VARCHAR | Quality tier: H=High, M=Medium, L=Low |
| `size` | VARCHAR | Physical size (e.g. "58", "L", "XL") — blank if not applicable |
| `weight_lbs` | VARCHAR | Weight in pounds — blank if not applicable |

**Original AdventureWorks table:** `Production.Product`

---

### `erp.inventory_levels` — 1,069 rows
Current stock on hand. Shows how many units of each product are sitting at each specific shelf and bin within a warehouse location. One row per unique product + location + shelf + bin combination.

| Column | Type | Description |
|---|---|---|
| `product_id` | VARCHAR | Foreign Key (FK) — links to `erp.products.product_id` |
| `location_id` | VARCHAR | Foreign Key (FK) — links to `erp.locations.location_id` |
| `shelf` | VARCHAR | The shelf label within the location (e.g. "A", "B") |
| `bin` | VARCHAR | The bin number within the shelf (e.g. "1", "2") — a bin is a specific slot or container |
| `qty_on_hand` | INTEGER | How many units are currently in this location |
| `last_updated` | DATE | The date this count was last recorded or updated |

**Original AdventureWorks table:** `Production.ProductInventory`

---

### `erp.locations` — 14 rows
The warehouse and production floor locations where inventory can be held. These are the places referenced by `erp.inventory_levels`.

| Column | Type | Description |
|---|---|---|
| `location_id` | VARCHAR | Unique identifier for the location |
| `location_name` | VARCHAR | Human-readable name (e.g. "Tool Crib", "Finished Goods Storage", "Frame Forming") |
| `cost_rate` | DECIMAL(8,2) | Hourly operating cost for this location (in dollars per hour) |
| `capacity` | DECIMAL(8,2) | Available working capacity in hours per week |

**Original AdventureWorks table:** `Production.Location`

---

### `erp.work_orders` — 72,591 rows
Production work orders. A work order is an instruction to the factory floor: "make this many units of this product by this date." Each row tracks one such order from start to finish.

| Column | Type | Description |
|---|---|---|
| `wo_id` | VARCHAR | Unique work order identifier |
| `product_id` | VARCHAR | Foreign Key (FK) — which product is being made |
| `qty_required` | INTEGER | How many units were ordered to be made |
| `qty_stocked` | INTEGER | How many units were completed and moved into stock |
| `qty_scrapped` | INTEGER | How many units were rejected or discarded during production |
| `start_date` | DATE | When production actually began (or was planned to begin) |
| `end_date` | DATE | When production actually finished |
| `due_date` | DATE | The deadline by which the order must be completed |

**Original AdventureWorks table:** `Production.WorkOrder`

---

## Schema: `procurement`

Simulates the company's **procurement system** — the system that manages buying goods from outside suppliers. In some companies this is a module inside the ERP; in others it is a standalone platform (e.g. Coupa, SAP Ariba).

---

### `procurement.vendors` — 104 rows
The approved supplier list. Only suppliers on this list are authorized to receive purchase orders from the company.

| Column | Type | Description |
|---|---|---|
| `vendor_id` | VARCHAR | Unique identifier for the vendor |
| `account_number` | VARCHAR | The company's internal account number for this vendor |
| `vendor_name` | VARCHAR | The vendor's company name |
| `credit_rating` | INTEGER | Credit rating from 1 to 5 (1 = Superior, 2 = Excellent, 3 = Above Average, 4 = Average, 5 = Below Average) |
| `is_active` | BOOLEAN | True if the vendor is currently authorized to receive orders |
| `is_preferred` | BOOLEAN | True if the vendor has been given preferred status (better terms, priority) |
| `last_updated` | DATE | Date the vendor record was last modified |

**Original AdventureWorks table:** `Purchasing.Vendor` (primary key mapped from `BusinessEntityID`)

---

### `procurement.purchase_orders` — 4,012 rows
Purchase order (PO) headers. Each row represents one PO — the top-level agreement to buy goods from a vendor. The actual products and quantities ordered are in `po_lines`.

| Column | Type | Description |
|---|---|---|
| `po_id` | VARCHAR | Unique Purchase Order identifier |
| `vendor_id` | VARCHAR | Foreign Key (FK) — which vendor this PO was sent to |
| `status` | VARCHAR | Current state: PENDING (created), APPROVED (authorized), REJECTED (denied), COMPLETE (fulfilled) |
| `status_code` | INTEGER | Numeric version of status: 1=PENDING, 2=APPROVED, 3=REJECTED, 4=COMPLETE |
| `order_date` | DATE | Date the PO was created |
| `ship_date` | DATE | Date the goods were shipped by the vendor |
| `subtotal` | DECIMAL(12,2) | Order value before tax (in dollars) |
| `tax_amount` | DECIMAL(12,2) | Tax charged (in dollars) |
| `total_due` | DECIMAL(12,2) | Total amount owed to the vendor including tax (in dollars) |

**Original AdventureWorks table:** `Purchasing.PurchaseOrderHeader`

---

### `procurement.po_lines` — 8,845 rows
Purchase order line items. Each PO can contain multiple products — one row per product per PO. This table contains the details of what was ordered, at what price, and how much was actually delivered.

| Column | Type | Description |
|---|---|---|
| `po_id` | VARCHAR | Foreign Key (FK) — links to `procurement.purchase_orders.po_id` |
| `line_id` | VARCHAR | Unique identifier for this individual line within the PO |
| `product_id` | VARCHAR | Foreign Key (FK) — which product was ordered |
| `qty_ordered` | INTEGER | How many units were ordered |
| `unit_price` | DECIMAL(12,2) | The agreed price per unit (in dollars) |
| `qty_received` | DECIMAL(12,3) | How many units were physically received from the vendor |
| `qty_rejected` | DECIMAL(12,3) | How many received units failed inspection and were rejected |
| `qty_stocked` | DECIMAL(12,3) | How many units passed inspection and were accepted into stock |
| `due_date` | DATE | The date by which delivery was expected |

**Original AdventureWorks table:** `Purchasing.PurchaseOrderDetail`

---

## Schema: `wms`

Simulates the company's **Warehouse Management System (WMS)** — software that tracks the physical movement of stock in and out of warehouses. This schema is **synthetic** (generated data, not from AdventureWorks) because AdventureWorks does not include warehouse movement records.

---

### `wms.warehouses` — 4 rows
The physical warehouse facilities the company operates.

| Column | Type | Description |
|---|---|---|
| `warehouse_id` | VARCHAR | Unique identifier for the warehouse (e.g. "WH-EAST") |
| `warehouse_name` | VARCHAR | Descriptive name (e.g. "East Distribution Center") |
| `city` | VARCHAR | City and state where the warehouse is located |
| `capacity_sqft` | INTEGER | Total floor area in square feet |

**Source:** Synthetic

---

### `wms.stock_movements` — 500 rows
A log of every time inventory physically moved — received from a vendor, shipped to a customer, or adjusted due to a count correction. One row per movement event.

| Column | Type | Description |
|---|---|---|
| `movement_id` | VARCHAR | Unique identifier for this movement event |
| `product_id` | VARCHAR | Foreign Key (FK) — which product moved |
| `location_id` | VARCHAR | Foreign Key (FK) — which warehouse location it moved to/from |
| `movement_type` | VARCHAR | What kind of movement: RECEIPT (goods arrived), SHIPMENT (goods sent out), ADJUSTMENT (manual correction to stock count) |
| `quantity` | INTEGER | Number of units involved in the movement |
| `movement_date` | DATE | Date the movement occurred |
| `reference_doc` | VARCHAR | The document that authorized or triggered this movement (e.g. a PO number or shipment ID) |

**Source:** Synthetic — generated using product and location combinations from `erp.inventory_levels`

---

## Cross-Schema Relationships

The three schemas are connected through shared identifier columns. This is how a data pipeline can join them together to answer questions that span multiple systems.

```
erp.products ──────────────────── product_id ──── erp.inventory_levels
erp.products ──────────────────── product_id ──── erp.work_orders
erp.products ──────────────────── product_id ──── procurement.po_lines
erp.locations ─────────────────── location_id ─── erp.inventory_levels
erp.locations ─────────────────── location_id ─── wms.stock_movements
procurement.vendors ───────────── vendor_id ────── procurement.purchase_orders
procurement.purchase_orders ────── po_id ──────── procurement.po_lines
procurement.po_lines ──────────── product_id ──── erp.products
wms.stock_movements ───────────── product_id ──── erp.products
```

`erp.products` is the central table — it connects all three systems through `product_id`.
