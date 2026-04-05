#!/bin/bash
# Test runner for Dispatcher Agent pipeline
# Runs all 21 tests sequentially, captures results

WEBHOOK="http://localhost:5678/webhook/dispatcher"
RESULTS_DIR="/Users/thinhpham/Dev/n8n/test_results"
mkdir -p "$RESULTS_DIR"

run_test() {
  local num="$1"
  local question="$2"
  local outfile="$RESULTS_DIR/T${num}.json"

  echo "=========================================="
  echo "T${num}: ${question}"
  echo "=========================================="

  local start_time=$(date +%s)

  curl -s -X POST "$WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "{\"user_request\": \"${question}\"}" \
    --max-time 180 \
    -o "$outfile" 2>/dev/null

  local exit_code=$?
  local end_time=$(date +%s)
  local elapsed=$((end_time - start_time))

  if [ $exit_code -ne 0 ]; then
    echo "  TIMEOUT/ERROR after ${elapsed}s (exit code: $exit_code)"
    echo "{\"error\": \"curl failed with exit code $exit_code after ${elapsed}s\"}" > "$outfile"
  else
    # Extract key fields
    local routing=$(python3 -c "import json; d=json.load(open('$outfile')); print(d.get('routing','N/A'))" 2>/dev/null)
    local status=$(python3 -c "import json; d=json.load(open('$outfile')); print(d.get('status','N/A'))" 2>/dev/null)
    local answer_len=$(python3 -c "import json; d=json.load(open('$outfile')); print(len(str(d.get('answer',''))))" 2>/dev/null)
    local vault_created=$(python3 -c "import json; d=json.load(open('$outfile')); print(d.get('vault_tables_created','N/A'))" 2>/dev/null)
    local mart_rows=$(python3 -c "
import json
d=json.load(open('$outfile'))
a = d.get('answer','')
if isinstance(a, list): print(len(a))
elif isinstance(a, dict) and 'rows' in a: print(len(a['rows']))
else: print('text')
" 2>/dev/null)

    echo "  Time: ${elapsed}s | Routing: $routing | Status: $status | Answer length: $answer_len | Rows: $mart_rows"
    echo "  Vault created: $vault_created"
  fi
  echo ""
}

echo "Starting test suite at $(date)"
echo "Cleaning vault..."
curl -s -X POST http://localhost:8001/query -H 'Content-Type: application/json' \
  -d '{"sql": "SELECT table_name FROM information_schema.tables WHERE table_schema = '\''main'\'' AND table_name NOT IN ('\''_vault_registry'\'', '\''_mart_registry'\'')", "database": "/data/vault.duckdb"}' \
  | python3 -c "
import sys, json, requests
tables = [r['table_name'] for r in json.load(sys.stdin).get('rows', [])]
if tables:
    stmts = ['DROP TABLE IF EXISTS \"' + t + '\"' for t in tables]
    stmts.append('DELETE FROM _vault_registry')
    stmts.append('DELETE FROM _mart_registry')
    r = requests.post('http://localhost:8001/execute-batch', json={'statements': stmts, 'database': '/data/vault.duckdb'})
    d = r.json()
    print(f'Dropped {len(tables)} tables, cleared registries. Failed: {d.get(\"failed\",0)}')
else:
    print('Vault already clean.')
"
echo ""

# Level 1 — Single Source, Single Table
run_test 1 "How many products do we have in total?"
run_test 2 "List all warehouse locations and their capacity."
run_test 3 "Which vendors have a credit rating of 1 and are currently active?"

# Level 2 — Single Source, Aggregation + Grain
run_test 4 "What is the total quantity on hand for each location?"
run_test 5 "What is the scrap rate for each product that has work orders? Show the top 10 worst."
run_test 6 "How many purchase orders are in each status? What is the total dollar amount per status?"

# Level 3 — Cross-Schema Joins (Fan-out Territory)
run_test 7 "Which products are below their reorder point? Include the vendor names that supply each product."
run_test 8 "For each location, which products are below their reorder point at that specific location?"
run_test 9 "Which vendors have we spent the most money with? Show top 10 with total spend and number of POs."
run_test 10 "Compare each product's unit cost from ERP with the average purchase price from procurement. Which products have the biggest markup?"

# Level 4 — Three-System Joins
run_test 11 "Show total receipts, shipments, and adjustments for each product at each location."
run_test 12 "For each product, show: current stock on hand, reorder point, total units on order from purchase orders, and net stock movements from WMS."
run_test 13 "Which warehouses have the most stock movement activity?"

# Level 5 — QUERY_ONLY Routing (run after T7 built a mart)
run_test 14 "Which products are below their reorder point? Include the vendor names that supply each product."
run_test 15 "Show me products that need to be reordered, along with their suppliers."
run_test 16 "What is the average lead time for purchase orders by vendor?"

# Level 6 — Edge Cases
run_test 17 "How many tables are in the source database?"
run_test 18 "What about hex nuts?"
run_test 19 "Give me a complete inventory health dashboard: for each product, show current stock by location, reorder point, safety stock, active PO quantities on order, vendor names and credit ratings, and recent stock movements."
run_test 20 "Which products had work orders due in the last 30 days that are not complete yet where qty_stocked is less than qty_required?"
run_test 21 "Which products have a list price over 1000?"

echo "=========================================="
echo "Test suite complete at $(date)"
echo "Results saved to $RESULTS_DIR/"
echo "=========================================="

# Summary
echo ""
echo "SUMMARY:"
for i in $(seq 1 21); do
  f="$RESULTS_DIR/T${i}.json"
  if [ -f "$f" ]; then
    routing=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('routing','N/A'))" 2>/dev/null)
    status=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('status','N/A'))" 2>/dev/null)
    dq=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('dq_status',''))" 2>/dev/null)
    echo "  T${i}: routing=$routing status=$status dq=$dq"
  else
    echo "  T${i}: NO RESULT FILE"
  fi
done
