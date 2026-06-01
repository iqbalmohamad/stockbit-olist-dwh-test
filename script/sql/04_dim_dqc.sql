-- ============================================================
-- DQC — Dimensions
-- All results written to dqc_results table.
-- Run AFTER 02_load_dimensions.sql.
-- ============================================================

-- Clear previous dim DQC results before re-running
DELETE FROM dqc_results WHERE layer = 'dim';

-- ─── dim_date ─────────────────────────────────────────────────

-- Check: expected row count (2015-01-01 to 2022-12-31 = 2922 days)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_date', 'expected_row_count',
    CASE WHEN COUNT(*) = 2922 THEN 'PASS' ELSE 'FAIL' END,
    ABS(COUNT(*) - 2922),
    'Expected 2922 rows (2015-2022 date spine)'
FROM dim_date;

-- Check: unique date_key
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_date', 'unique_date_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*),
    'Duplicate date_key values found'
FROM (SELECT date_key FROM dim_date GROUP BY date_key HAVING COUNT(*) > 1);

-- Check: no NULL full_date
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_date', 'no_null_full_date',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'NULL full_date values found'
FROM dim_date WHERE full_date IS NULL;

-- ─── dim_customer ─────────────────────────────────────────────

-- Check: unique customer_key (PK)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_customer', 'unique_pk',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'Duplicate customer_key'
FROM (SELECT customer_key FROM dim_customer GROUP BY customer_key HAVING COUNT(*) > 1);

-- Check: unique customer_unique_id (business key)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_customer', 'unique_business_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'Duplicate customer_unique_id'
FROM (SELECT customer_unique_id FROM dim_customer GROUP BY customer_unique_id HAVING COUNT(*) > 1);

-- Check: no NULL customer_state
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_customer', 'no_null_state',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'NULL customer_state values'
FROM dim_customer WHERE customer_state IS NULL;

-- ─── dim_seller ───────────────────────────────────────────────

-- Check: unique seller_key (PK)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_seller', 'unique_pk',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'Duplicate seller_key'
FROM (SELECT seller_key FROM dim_seller GROUP BY seller_key HAVING COUNT(*) > 1);

-- Check: unique seller_id (business key)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_seller', 'unique_business_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'Duplicate seller_id'
FROM (SELECT seller_id FROM dim_seller GROUP BY seller_id HAVING COUNT(*) > 1);

-- ─── dim_seller_hist ──────────────────────────────────────────

-- Check: at most 1 is_current=TRUE per seller_id
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_seller_hist', 'scd2_single_current_per_seller',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'seller_id has more than 1 is_current=TRUE record'
FROM (
    SELECT seller_id FROM dim_seller_hist
    WHERE is_current = TRUE
    GROUP BY seller_id HAVING COUNT(*) > 1
);

-- Check: scd_end_date > scd_start_date where not null
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_seller_hist', 'scd2_end_after_start',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'scd_end_date <= scd_start_date'
FROM dim_seller_hist
WHERE scd_end_date IS NOT NULL
  AND scd_end_date <= scd_start_date;

-- Check: every seller in dim_seller has a hist record
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_seller_hist', 'referential_seller_coverage',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'seller_id in dim_seller missing from dim_seller_hist'
FROM dim_seller s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_seller_hist h WHERE h.seller_id = s.seller_id
);

-- ─── dim_product ──────────────────────────────────────────────

-- Check: unique product_key (PK)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_product', 'unique_pk',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'Duplicate product_key'
FROM (SELECT product_key FROM dim_product GROUP BY product_key HAVING COUNT(*) > 1);

-- Check: no NULL category_name (should be 'unknown' not NULL after cleansing)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_product', 'no_null_category',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'NULL category_name (expected unknown instead)'
FROM dim_product WHERE category_name IS NULL;

-- ─── dim_product_hist ─────────────────────────────────────────

-- Check: at most 1 is_current=TRUE per product_id
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_product_hist', 'scd2_single_current_per_product',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'product_id has more than 1 is_current=TRUE record'
FROM (
    SELECT product_id FROM dim_product_hist
    WHERE is_current = TRUE
    GROUP BY product_id HAVING COUNT(*) > 1
);

-- Check: every product in dim_product has a hist record
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_product_hist', 'referential_product_coverage',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'product_id in dim_product missing from dim_product_hist'
FROM dim_product p
WHERE NOT EXISTS (
    SELECT 1 FROM dim_product_hist h WHERE h.product_id = p.product_id
);

-- ─── dim_order_flags ──────────────────────────────────────────

-- Check: exactly 32 rows (8 statuses × 2 × 2)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_order_flags', 'expected_row_count',
    CASE WHEN COUNT(*) = 32 THEN 'PASS' ELSE 'FAIL' END,
    ABS(COUNT(*) - 32),
    'Expected exactly 32 junk dimension combinations'
FROM dim_order_flags;

-- ─── dim_payment_type ─────────────────────────────────────────

-- Check: exactly 5 rows
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'dim', 'dim_payment_type', 'expected_row_count',
    CASE WHEN COUNT(*) = 5 THEN 'PASS' ELSE 'FAIL' END,
    ABS(COUNT(*) - 5),
    'Expected exactly 5 payment types'
FROM dim_payment_type;