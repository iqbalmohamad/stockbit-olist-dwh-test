"""
Olist DWH API
=============
FastAPI app that serves analytics data from the Olist DuckDB warehouse.

Run:
    uvicorn api:app --reload --port 8000

Docs (auto-generated):
    http://localhost:8000/docs
"""

import os
import threading
from typing import Optional

import duckdb
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel

# ─── Config ──────────────────────────────────────────────────

def _root() -> str:
    """Project root = 2 levels up from script/py/api.py"""
    here = os.path.dirname(os.path.abspath(__file__))   # .../script/py/
    return os.path.dirname(os.path.dirname(here))        # project root


DB_PATH = os.environ.get(
    "DWH_PATH",
    os.path.join(_root(), "db", "olist_dwh.duckdb")
)

# ─── DB Connection ───────────────────────────────────────────
# One read-only DuckDB connection per thread.
# read_only=True lets DBeaver/pipeline stay connected concurrently.

_local = threading.local()

def get_conn() -> duckdb.DuckDBPyConnection:
    if not hasattr(_local, "conn"):
        if not os.path.exists(DB_PATH):
            raise RuntimeError(f"DWH file not found: {DB_PATH}\nRun run_pipeline.py first.")
        _local.conn = duckdb.connect(DB_PATH, read_only=True)
    return _local.conn


def query(sql: str, params: list = []) -> list[dict]:
    """Execute SQL and return list of dicts."""
    con = get_conn()
    result = con.execute(sql, params)
    cols = [d[0] for d in result.description]
    return [dict(zip(cols, row)) for row in result.fetchall()]


# ─── App ─────────────────────────────────────────────────────

app = FastAPI(
    title="Olist DWH API",
    description=(
        "Analytics API over the Olist Brazilian e-commerce data warehouse. "
        "Built on DuckDB + Kimball star schema. "
        "All endpoints are read-only."
    ),
    version="1.0.0",
)

# ─── Pydantic Models ─────────────────────────────────────────

class HealthResponse(BaseModel):
    status: str
    db_path: str
    row_counts: dict[str, int]


class SellerItem(BaseModel):
    seller_id: str
    seller_city: Optional[str]
    seller_state: Optional[str]
    seller_zip_code: Optional[str]


class SellerSnapshotItem(BaseModel):
    year_month: str
    total_orders: int
    total_items_sold: int
    total_revenue: float
    total_freight: float
    avg_review_score: Optional[float]
    avg_delivery_delay_days: Optional[float]


class OrderLifecycleResponse(BaseModel):
    order_id: str
    order_status: Optional[str]
    order_purchase_date: str
    approval_delay_hours: Optional[float]
    carrier_pickup_delay_hours: Optional[float]
    delivery_delay_days: Optional[float]
    vs_estimated_days: Optional[float]
    is_late: Optional[bool]


class CategoryRevenueItem(BaseModel):
    category_name_english: str
    total_orders: int
    total_items: int
    total_revenue: float
    avg_price: float
    avg_freight: float


class DQCResult(BaseModel):
    layer: str
    table_name: str
    check_name: str
    status: str
    failed_count: int
    note: Optional[str]


# ─── Endpoints ───────────────────────────────────────────────

@app.get("/health", response_model=HealthResponse, tags=["Meta"])
def health():
    """Health check — returns status and row counts for all DWH tables."""
    tables = [
        "dim_date", "dim_customer", "dim_seller", "dim_seller_hist",
        "dim_product", "dim_product_hist", "dim_payment_type", "dim_order_flags",
        "fct_order_items", "fct_order_lifecycle", "fct_seller_monthly_snapshot",
    ]
    counts = {}
    try:
        for t in tables:
            counts[t] = query(f"SELECT COUNT(*) AS n FROM {t}")[0]["n"]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    return HealthResponse(status="ok", db_path=DB_PATH, row_counts=counts)


@app.get("/sellers", response_model=list[SellerItem], tags=["Sellers"])
def list_sellers(
    state: Optional[str] = Query(None, description="Filter by state code, e.g. SP"),
    city:  Optional[str] = Query(None, description="Filter by city name (partial match)"),
    limit: int           = Query(50, ge=1, le=500, description="Max rows to return"),
):
    """
    List sellers from dim_seller (current values).
    Filter by state or city. Results sorted by state, city.
    """
    where, params = [], []
    if state:
        where.append("UPPER(seller_state) = UPPER(?)")
        params.append(state)
    if city:
        where.append("seller_city ILIKE ?")
        params.append(f"%{city}%")

    clause = "WHERE " + " AND ".join(where) if where else ""
    sql = f"""
        SELECT seller_id, seller_city, seller_state, seller_zip_code
        FROM dim_seller
        {clause}
        ORDER BY seller_state, seller_city
        LIMIT {limit}
    """
    return query(sql, params)


@app.get("/sellers/{seller_id}/snapshot", response_model=list[SellerSnapshotItem], tags=["Sellers"])
def seller_snapshot(
    seller_id: str,
    months: int = Query(12, ge=1, le=60, description="How many recent months to return"),
):
    """
    Monthly performance snapshot for a seller.
    Source: fct_seller_monthly_snapshot.
    Measures: revenue, orders, avg review score, avg delivery delay.
    Note: avg_* are semi-additive — do not sum across months.
    """
    # Verify seller exists
    found = query("SELECT 1 FROM dim_seller WHERE seller_id = ?", [seller_id])
    if not found:
        raise HTTPException(status_code=404, detail=f"Seller '{seller_id}' not found")

    sql = """
        SELECT
            s.snapshot_year_month       AS year_month,
            s.total_orders,
            s.total_items_sold,
            ROUND(s.total_revenue, 2)   AS total_revenue,
            ROUND(s.total_freight, 2)   AS total_freight,
            ROUND(s.avg_review_score, 2) AS avg_review_score,
            ROUND(s.avg_delivery_delay_days, 2) AS avg_delivery_delay_days
        FROM fct_seller_monthly_snapshot s
        JOIN dim_seller ds ON s.seller_key = ds.seller_key
        WHERE ds.seller_id = ?
        ORDER BY s.snapshot_year_month DESC
        LIMIT ?
    """
    rows = query(sql, [seller_id, months])
    if not rows:
        raise HTTPException(status_code=404, detail=f"No snapshot data for seller '{seller_id}'")
    return rows


@app.get("/orders/{order_id}/lifecycle", response_model=OrderLifecycleResponse, tags=["Orders"])
def order_lifecycle(order_id: str):
    """
    Stage-by-stage lifecycle for a single order.
    Source: fct_order_lifecycle (accumulating snapshot).
    Measures are semi-additive delays between pipeline stages.
    """
    sql = """
        SELECT
            fl.order_id,
            dof.order_status,
            fl.order_purchase_date::VARCHAR          AS order_purchase_date,
            ROUND(fl.approval_delay_hours, 2)        AS approval_delay_hours,
            ROUND(fl.carrier_pickup_delay_hours, 2)  AS carrier_pickup_delay_hours,
            ROUND(fl.delivery_delay_days, 2)         AS delivery_delay_days,
            ROUND(fl.vs_estimated_days, 2)           AS vs_estimated_days,
            dof.is_late_delivery                     AS is_late
        FROM fct_order_lifecycle fl
        LEFT JOIN dim_order_flags dof ON fl.order_flags_key = dof.order_flags_key
        WHERE fl.order_id = ?
    """
    rows = query(sql, [order_id])
    if not rows:
        raise HTTPException(status_code=404, detail=f"Order '{order_id}' not found")
    return rows[0]


@app.get("/revenue/by-category", response_model=list[CategoryRevenueItem], tags=["Revenue"])
def revenue_by_category(
    date_from: Optional[str] = Query(None, description="Start date YYYY-MM-DD"),
    date_to:   Optional[str] = Query(None, description="End date YYYY-MM-DD"),
    limit:     int           = Query(20, ge=1, le=100),
):
    """
    Revenue breakdown by product category.
    Source: fct_order_items (transaction grain) joined to dim_product.
    Measures are fully additive — safe to SUM across all dimensions.
    """
    where, params = [], []
    if date_from:
        where.append("fi.order_purchase_date >= ?")
        params.append(date_from)
    if date_to:
        where.append("fi.order_purchase_date <= ?")
        params.append(date_to)

    clause = "WHERE " + " AND ".join(where) if where else ""
    sql = f"""
        SELECT
            dp.category_name_english,
            COUNT(DISTINCT fi.order_id)    AS total_orders,
            COUNT(*)                       AS total_items,
            ROUND(SUM(fi.price), 2)        AS total_revenue,
            ROUND(AVG(fi.price), 2)        AS avg_price,
            ROUND(AVG(fi.freight_value), 2) AS avg_freight
        FROM fct_order_items fi
        JOIN dim_product dp ON fi.product_key = dp.product_key
        {clause}
        GROUP BY dp.category_name_english
        ORDER BY total_revenue DESC
        LIMIT {limit}
    """
    return query(sql, params)


@app.get("/dqc", response_model=list[DQCResult], tags=["Meta"])  # type: ignore[misc]
def dqc_results(
    layer:  Optional[str] = Query(None, description="Filter by layer: dim or fct"),
    status: Optional[str] = Query(None, description="Filter by status: PASS or FAIL"),
):
    """
    Latest DQC check results from the most recent pipeline run.
    Shows data quality status for all dimension and fact tables.
    """
    where, params = [], []
    if layer:
        where.append("layer = ?")
        params.append(layer.lower())
    if status:
        where.append("UPPER(status) = UPPER(?)")
        params.append(status)

    clause = "WHERE " + " AND ".join(where) if where else ""

    # Get only the most recent run's results
    sql = f"""
        WITH latest AS (
            SELECT MAX(run_timestamp) AS max_ts FROM dqc_results
        )
        SELECT layer, table_name, check_name, status, failed_count, note
        FROM dqc_results, latest
        WHERE run_timestamp = max_ts
          {('AND ' + ' AND '.join(where)) if where else ''}
        ORDER BY layer, table_name, check_name
    """
    return query(sql, params)


# ─── Entry Point ─────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    print("Starting Olist DWH API...")
    print("Swagger docs: http://localhost:8000/docs")
    uvicorn.run("api:app", host="0.0.0.0", port=8000, reload=True)