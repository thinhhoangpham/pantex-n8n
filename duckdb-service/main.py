from typing import Optional, Any
import math

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import duckdb

app = FastAPI(title="DuckDB Service")

def _sanitize_for_json(value: Any) -> Any:
    """
    FastAPI/JSON can't serialize NaN/Inf. DuckDB results may contain them,
    so convert to None (which becomes JSON null).
    """
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            return None
        return value
    return value


def sanitize_payload(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: sanitize_payload(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize_payload(v) for v in obj]
    return _sanitize_for_json(obj)


class QueryRequest(BaseModel):
    sql: str
    database: Optional[str] = None


class BatchRequest(BaseModel):
    statements: list[str]
    database: str = "/data/vault.duckdb"


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/query")
def run_query(req: QueryRequest):
    try:
        conn = duckdb.connect(req.database if req.database else ":memory:")
        result = conn.execute(req.sql).fetchdf()
        rows = sanitize_payload(result.to_dict(orient="records"))
        return {
            "status": "success",
            "columns": list(result.columns),
            "rows": rows,
            "row_count": len(result),
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/describe")
def describe_query(req: QueryRequest):
    try:
        conn = duckdb.connect()
        result = conn.execute(f"DESCRIBE ({req.sql})").fetchdf()
        return {
            "status": "success",
            "schema": result.to_dict(orient="records"),
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/execute-batch")
def execute_batch(req: BatchRequest):
    results = []
    conn = duckdb.connect(req.database)
    try:
        for i, sql in enumerate(req.statements):
            sql_preview = sql[:80]
            try:
                cursor = conn.execute(sql)
                rows_affected = cursor.rowcount if cursor.rowcount is not None else 0
                results.append({
                    "index": i,
                    "sql_preview": sql_preview,
                    "status": "success",
                    "rows_affected": rows_affected,
                    "error": None,
                })
            except Exception as e:
                results.append({
                    "index": i,
                    "sql_preview": sql_preview,
                    "status": "error",
                    "rows_affected": 0,
                    "error": str(e),
                })
    finally:
        conn.close()

    total = len(results)
    succeeded = sum(1 for r in results if r["status"] == "success")
    failed = total - succeeded

    return {
        "status": "success" if failed == 0 else "partial_failure",
        "total": total,
        "succeeded": succeeded,
        "failed": failed,
        "results": results,
    }
