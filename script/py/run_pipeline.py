"""
Olist DWH Pipeline Runner — IDEMPOTENT
=======================================
Connects to existing DuckDB (creates if not exists), wires raw
parquet views, then runs DDL → dimensions → facts → DQC in order.

Running this multiple times produces the same result:
  - DDL:   CREATE TABLE/SEQUENCE IF NOT EXISTS (safe to re-run)
  - Dims:  MERGE for SCD1, 3-step UPDATE/INSERT for SCD2
  - Facts: DELETE on natural key + INSERT fresh
  - DQC:   PASS/FAIL results written to dqc_results table

Usage:
    python run_pipeline.py [--data-path PATH] [--db-path PATH]

Defaults:
    --data-path : <project_root>/olist_dataset/
    --db-path   : <project_root>/db/olist_dwh.duckdb

Folder structure expected:
    stockbit-olist-dwh-test/
    ├── db/                  ← DWH file generated here
    ├── olist_dataset/       ← parquet source files
    └── script/
        ├── sql/             ← SQL files
        └── py/
            └── run_pipeline.py  ← this file
"""

import argparse
import os
import re
import sys
import duckdb


# ─── Config ──────────────────────────────────────────────────

PARQUET_FILES = {
    "raw_customers":            "olist_customers_dataset.parquet",
    "raw_order_items":          "olist_order_items_dataset.parquet",
    "raw_payments":             "olist_order_payments_dataset.parquet",
    "raw_reviews":              "olist_order_reviews_dataset.parquet",
    "raw_orders":               "olist_orders_dataset.parquet",
    "raw_products":             "olist_products_dataset.parquet",
    "raw_sellers":              "olist_sellers_dataset_city.parquet",
    "raw_category_translation": "product_category_name_translation.parquet",
}

SQL_FILES = [
    "01_ddl.sql",
    "02_load_dimensions.sql",
    "03_load_facts.sql",
    "04_dim_dqc.sql",
    "05_fct_dqc.sql",
]

DWH_TABLES = [
    "dim_date",
    "dim_customer",
    "dim_seller",
    "dim_seller_hist",
    "dim_product",
    "dim_product_hist",
    "dim_payment_type",
    "dim_order_flags",
    "fct_order_items",
    "fct_order_lifecycle",
    "fct_seller_monthly_snapshot",
]


# ─── Helpers ─────────────────────────────────────────────────

def _root() -> str:
    """Project root = 2 levels up from script/py/run_pipeline.py"""
    here = os.path.dirname(os.path.abspath(__file__))   # .../script/py/
    return os.path.dirname(os.path.dirname(here))        # project root


ROOT    = _root()
SQL_DIR = os.path.join(ROOT, "script", "sql")


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--data-path", default=os.path.join(ROOT, "olist_dataset"))
    p.add_argument("--db-path",   default=os.path.join(ROOT, "db", "olist_dwh.duckdb"))
    return p.parse_args()


def split_statements(sql: str) -> list[str]:
    """Split SQL file into individual statements, stripping line comments."""
    sql = re.sub(r'--[^\n]*', '', sql)
    stmts = [s.strip() for s in sql.split(';')]
    return [s for s in stmts if s]


def execute_file(con: duckdb.DuckDBPyConnection, filepath: str) -> None:
    label = os.path.basename(filepath)
    print(f"\n▶ {label}")
    with open(filepath, "r", encoding="utf-8") as f:
        sql = f.read()
    statements = split_statements(sql)
    for i, stmt in enumerate(statements, 1):
        try:
            con.execute(stmt)
        except Exception as e:
            print(f"  ✗ Statement {i} failed:\n    {stmt[:120]}...\n  Error: {e}")
            raise
    print(f"  ✓ {len(statements)} statements executed")


def create_raw_views(con: duckdb.DuckDBPyConnection, data_path: str) -> None:
    print("\n▶ Creating raw views from parquet files")
    for view_name, filename in PARQUET_FILES.items():
        full_path = os.path.join(data_path, filename).replace("\\", "/")
        if not os.path.exists(full_path):
            print(f"  ✗ File not found: {full_path}")
            sys.exit(1)
        con.execute(f"""
            CREATE OR REPLACE VIEW {view_name} AS
            SELECT * FROM read_parquet('{full_path}')
        """)
    print(f"  ✓ {len(PARQUET_FILES)} views created")


def print_row_counts(con: duckdb.DuckDBPyConnection) -> None:
    print("\n" + "=" * 50)
    print("DWH Row Counts")
    print("=" * 50)
    for table in DWH_TABLES:
        count = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"  {table:<35} {count:>10,} rows")


def print_dqc_summary(con: duckdb.DuckDBPyConnection) -> None:
    results = con.execute("""
        SELECT layer, table_name, check_name, status, failed_count, note
        FROM dqc_results
        ORDER BY layer, table_name, check_name
    """).fetchall()

    total   = len(results)
    passed  = sum(1 for r in results if r[3] == 'PASS')
    failed  = total - passed

    print("\n" + "=" * 50)
    print(f"DQC Summary  —  {passed}/{total} PASS  |  {failed} FAIL")
    print("=" * 50)

    if failed > 0:
        print("\n  FAILURES:")
        for r in results:
            if r[3] == 'FAIL':
                print(f"  ✗ [{r[0]}] {r[1]}.{r[2]}  →  {r[4]} rows  |  {r[5]}")

    print("\n  ALL CHECKS:")
    for r in results:
        icon = "✓" if r[3] == 'PASS' else "✗"
        print(f"  {icon} [{r[0]}] {r[1]}.{r[2]}")

    print("=" * 50)
    if failed > 0:
        print(f"\n  ⚠ {failed} DQC check(s) FAILED — review dqc_results table for details")
    else:
        print("\n  All DQC checks PASSED")


# ─── Main ────────────────────────────────────────────────────

def main():
    args = parse_args()

    # Ensure db/ folder exists
    os.makedirs(os.path.dirname(args.db_path), exist_ok=True)

    # Connect — creates DB file if not exists, reuses if exists
    print(f"Connecting to: {args.db_path}")
    con = duckdb.connect(args.db_path)

    try:
        create_raw_views(con, args.data_path)

        for sql_file in SQL_FILES:
            filepath = os.path.join(SQL_DIR, sql_file)
            execute_file(con, filepath)

        print_row_counts(con)
        print_dqc_summary(con)
        # Flush WAL → main file so read-only connections (API, DBeaver) can open cleanly
        con.execute("CHECKPOINT")
        print(f"\nDone. DWH available at: {args.db_path}")

    except Exception as e:
        print(f"\nPipeline failed: {e}")
        sys.exit(1)
    finally:
        con.close()


if __name__ == "__main__":
    main()