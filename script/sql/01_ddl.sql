-- ============================================================
-- DDL: Olist Data Warehouse
-- Engine  : DuckDB
-- Model   : Kimball Star Schema
-- Updated : 2026-06-01
-- ============================================================
-- Partition/cluster annotations are logical (BigQuery mapping);
-- DuckDB enforces physical order via load-time sorting instead.
-- ============================================================

-- ─── SEQUENCES (surrogate keys) ──────────────────────────────

CREATE SEQUENCE IF NOT EXISTS seq_customer_key     START 1;
CREATE SEQUENCE IF NOT EXISTS seq_seller_key       START 1;
CREATE SEQUENCE IF NOT EXISTS seq_seller_hist_key  START 1;
CREATE SEQUENCE IF NOT EXISTS seq_product_key      START 1;
CREATE SEQUENCE IF NOT EXISTS seq_product_hist_key START 1;
CREATE SEQUENCE IF NOT EXISTS seq_order_flags_key  START 1;
CREATE SEQUENCE IF NOT EXISTS seq_order_item_key   START 1;
CREATE SEQUENCE IF NOT EXISTS seq_lifecycle_key    START 1;
CREATE SEQUENCE IF NOT EXISTS seq_snapshot_key     START 1;

-- ─── DIMENSIONS ──────────────────────────────────────────────

-- dim_date
-- Static date spine, no SCD needed.
-- Partition : n/a (~2190 rows for 6-year range)
CREATE TABLE IF NOT EXISTS dim_date (
    date_key     INTEGER PRIMARY KEY,   -- YYYYMMDD
    full_date    DATE    NOT NULL,
    year         INTEGER NOT NULL,
    quarter      INTEGER NOT NULL,
    month        INTEGER NOT NULL,
    month_name   VARCHAR NOT NULL,
    week_of_year INTEGER NOT NULL,
    day_of_week  INTEGER NOT NULL,      -- 0=Sunday … 6=Saturday
    day_name     VARCHAR NOT NULL,
    is_weekend   BOOLEAN NOT NULL
);

-- dim_customer
-- SCD Type 1 only — all attributes overwritten on change.
-- Grain      : 1 row per customer_unique_id (real customer)
-- Cluster    : customer_state
CREATE TABLE IF NOT EXISTS dim_customer (
    customer_key       INTEGER PRIMARY KEY DEFAULT nextval('seq_customer_key'),
    customer_unique_id VARCHAR NOT NULL UNIQUE,
    customer_id        VARCHAR NOT NULL,    -- representative order-specific id
    customer_zip_code  VARCHAR,             -- SCD Type 1
    customer_city      VARCHAR,             -- SCD Type 1
    customer_state     VARCHAR              -- SCD Type 1
);

-- dim_seller
-- SCD Type 1 only.
-- Cluster : seller_state, seller_city
CREATE TABLE IF NOT EXISTS dim_seller (
    seller_key      INTEGER PRIMARY KEY DEFAULT nextval('seq_seller_key'),
    seller_id       VARCHAR NOT NULL UNIQUE,
    seller_zip_code VARCHAR,                -- SCD Type 1
    seller_city     VARCHAR,                -- SCD Type 1
    seller_state    VARCHAR                 -- SCD Type 1
);

-- dim_seller_hist
-- SCD Type 2 for city/state; SCD Type 1 for zip (overwrite all rows on zip change).
-- Partition : scd_start_date (MONTH)
-- Cluster   : seller_id, is_current
CREATE TABLE IF NOT EXISTS dim_seller_hist (
    seller_hist_key INTEGER PRIMARY KEY DEFAULT nextval('seq_seller_hist_key'),
    seller_id       VARCHAR NOT NULL,
    seller_zip_code VARCHAR,    -- SCD Type 1: UPDATE all rows for this seller_id
    seller_city     VARCHAR,    -- SCD Type 2: INSERT new row on change
    seller_state    VARCHAR,    -- SCD Type 2: INSERT new row on change
    scd_start_date  DATE    NOT NULL,
    scd_end_date    DATE,       -- NULL = current active record
    is_current      BOOLEAN NOT NULL DEFAULT TRUE
);

-- dim_product
-- SCD Type 1 only.
-- Cluster : category_name_english
-- Note    : source typo corrected — "lenght" → "length"
CREATE TABLE IF NOT EXISTS dim_product (
    product_key                INTEGER PRIMARY KEY DEFAULT nextval('seq_product_key'),
    product_id                 VARCHAR NOT NULL UNIQUE,
    category_name              VARCHAR,    -- SCD Type 1
    category_name_english      VARCHAR,    -- SCD Type 1
    product_name_length        INTEGER,    -- SCD Type 1 (source: product_name_lenght)
    product_description_length INTEGER,    -- SCD Type 1
    product_photos_qty         INTEGER,    -- SCD Type 1
    product_weight_g           INTEGER,    -- SCD Type 1
    product_length_cm          INTEGER,    -- SCD Type 1
    product_height_cm          INTEGER,    -- SCD Type 1
    product_width_cm           INTEGER     -- SCD Type 1
);

-- dim_product_hist
-- SCD Type 2 for category; SCD Type 1 for physical dimensions.
-- Partition : scd_start_date (MONTH)
-- Cluster   : product_id, is_current
CREATE TABLE IF NOT EXISTS dim_product_hist (
    product_hist_key      INTEGER PRIMARY KEY DEFAULT nextval('seq_product_hist_key'),
    product_id            VARCHAR NOT NULL,
    category_name         VARCHAR,    -- SCD Type 2: INSERT new row on change
    category_name_english VARCHAR,    -- SCD Type 2: INSERT new row on change
    product_weight_g      INTEGER,    -- SCD Type 1: UPDATE all rows for this product_id
    product_length_cm     INTEGER,    -- SCD Type 1
    product_height_cm     INTEGER,    -- SCD Type 1
    product_width_cm      INTEGER,    -- SCD Type 1
    scd_start_date        DATE    NOT NULL,
    scd_end_date          DATE,       -- NULL = current active record
    is_current            BOOLEAN NOT NULL DEFAULT TRUE
);

-- dim_payment_type
-- Static lookup. 5 rows (credit_card, boleto, voucher, debit_card, not_defined).
-- No partition/cluster needed.
CREATE TABLE IF NOT EXISTS dim_payment_type (
    payment_type_key INTEGER PRIMARY KEY,
    payment_type     VARCHAR NOT NULL UNIQUE,
    payment_type_desc VARCHAR
);

-- dim_order_flags  (JUNK DIMENSION)
-- Combines low-cardinality flags that don't belong to any single dimension.
-- Combinations: 8 statuses × 2 × 2 = max 32 rows.
-- No partition/cluster needed.
CREATE TABLE IF NOT EXISTS dim_order_flags (
    order_flags_key  INTEGER PRIMARY KEY DEFAULT nextval('seq_order_flags_key'),
    order_status     VARCHAR NOT NULL,
    is_late_delivery BOOLEAN NOT NULL,
    is_multi_item    BOOLEAN NOT NULL,
    UNIQUE (order_status, is_late_delivery, is_multi_item)
);

-- ─── FACTS ───────────────────────────────────────────────────

-- fct_order_items  (TRANSACTION GRAIN)
-- Grain     : 1 row per order item
-- Partition : order_purchase_date (DAY)
-- Cluster   : customer_key, seller_key, product_key
-- Measures  : price, freight_value, total_item_value — fully additive
CREATE TABLE IF NOT EXISTS fct_order_items (
    order_item_key      INTEGER PRIMARY KEY DEFAULT nextval('seq_order_item_key'),
    -- Foreign keys
    order_date_key      INTEGER NOT NULL REFERENCES dim_date(date_key),
    customer_key        INTEGER NOT NULL REFERENCES dim_customer(customer_key),
    seller_key          INTEGER NOT NULL REFERENCES dim_seller(seller_key),
    product_key         INTEGER NOT NULL REFERENCES dim_product(product_key),
    order_flags_key     INTEGER      REFERENCES dim_order_flags(order_flags_key),
    -- Degenerate dimensions
    order_id            VARCHAR NOT NULL,
    order_item_id       INTEGER NOT NULL,
    -- Measures (fully additive)
    price               DECIMAL(10,2) NOT NULL,
    freight_value       DECIMAL(10,2) NOT NULL,
    total_item_value    DECIMAL(10,2) NOT NULL,  -- price + freight_value
    -- Metadata
    shipping_limit_date TIMESTAMP,
    order_purchase_date DATE NOT NULL             -- partition key
);

-- fct_order_lifecycle  (ACCUMULATING SNAPSHOT)
-- Grain     : 1 row per order — row UPDATED as each stage completes
-- Partition : order_purchase_date (DAY)
-- Cluster   : customer_key, order_flags_key
-- Measures  : delay metrics — semi-additive (use AVG, not SUM)
-- Note      : 5 FK references to dim_date, one per lifecycle stage.
--             NULL date_key = stage not yet reached.
CREATE TABLE IF NOT EXISTS fct_order_lifecycle (
    order_lifecycle_key        INTEGER PRIMARY KEY DEFAULT nextval('seq_lifecycle_key'),
    -- Foreign keys — multiple date dimensions (one per stage)
    purchase_date_key          INTEGER REFERENCES dim_date(date_key),
    approved_date_key          INTEGER REFERENCES dim_date(date_key),
    carrier_date_key           INTEGER REFERENCES dim_date(date_key),
    delivered_date_key         INTEGER REFERENCES dim_date(date_key),
    estimated_date_key         INTEGER REFERENCES dim_date(date_key),
    customer_key               INTEGER NOT NULL REFERENCES dim_customer(customer_key),
    order_flags_key            INTEGER REFERENCES dim_order_flags(order_flags_key),
    -- Degenerate dimension
    order_id                   VARCHAR NOT NULL UNIQUE,
    -- Measures (semi-additive — use AVG per seller/region, not SUM)
    approval_delay_hours       DECIMAL(10,2),   -- purchase → approved
    carrier_pickup_delay_hours DECIMAL(10,2),   -- approved  → carrier pickup
    delivery_delay_days        DECIMAL(10,2),   -- carrier   → customer delivered
    vs_estimated_days          DECIMAL(10,2),   -- delivered vs estimated (+ = late, - = early)
    -- Partition key
    order_purchase_date        DATE NOT NULL
);

-- fct_seller_monthly_snapshot  (PERIODIC SNAPSHOT)
-- Grain     : 1 row per seller per calendar month — INSERT only, never updated
-- Partition : snapshot_year_month
-- Cluster   : seller_key
-- Measures  : total_* additive across sellers; avg_* semi-additive across time
CREATE TABLE IF NOT EXISTS fct_seller_monthly_snapshot (
    snapshot_key            INTEGER PRIMARY KEY DEFAULT nextval('seq_snapshot_key'),
    -- Foreign keys
    snapshot_month_key      INTEGER NOT NULL REFERENCES dim_date(date_key),
    seller_key              INTEGER NOT NULL REFERENCES dim_seller(seller_key),
    -- Measures
    total_orders            INTEGER       NOT NULL,   -- additive across sellers
    total_items_sold        INTEGER       NOT NULL,   -- additive across sellers
    total_revenue           DECIMAL(12,2) NOT NULL,   -- additive across sellers
    total_freight           DECIMAL(12,2) NOT NULL,   -- additive across sellers
    avg_review_score        DECIMAL(4,2),             -- semi-additive
    avg_delivery_delay_days DECIMAL(8,2),             -- semi-additive
    -- Partition key
    snapshot_year_month     VARCHAR NOT NULL           -- YYYY-MM
);

-- ─── DQC RESULTS TABLE ───────────────────────────────────────
-- Stores results of all data quality checks.
-- Not cleared between runs — append-only audit log.

CREATE TABLE IF NOT EXISTS dqc_results (
    run_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    layer         VARCHAR NOT NULL,   -- 'dim' or 'fct'
    table_name    VARCHAR NOT NULL,
    check_name    VARCHAR NOT NULL,
    status        VARCHAR NOT NULL,   -- 'PASS' or 'FAIL'
    failed_count  INTEGER NOT NULL,
    note          VARCHAR
);