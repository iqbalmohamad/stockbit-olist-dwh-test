-- ============================================================
-- DQC — Facts
-- All results written to dqc_results table.
-- Run AFTER 03_load_facts.sql and 04_dim_dqc.sql.
-- ============================================================

DELETE FROM dqc_results WHERE layer = 'fct';

-- ─── fct_order_items ──────────────────────────────────────────

-- Check: unique natural key (order_id, order_item_id)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'unique_natural_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'Duplicate (order_id, order_item_id)'
FROM (
    SELECT order_id, order_item_id
    FROM fct_order_items
    GROUP BY order_id, order_item_id HAVING COUNT(*) > 1
);

-- Check: no NULL customer_key, seller_key, product_key
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'no_null_dimension_keys',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'NULL FK: customer_key, seller_key, or product_key'
FROM fct_order_items
WHERE customer_key IS NULL OR seller_key IS NULL OR product_key IS NULL;

-- Check: price > 0
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'price_positive',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'price <= 0'
FROM fct_order_items WHERE price <= 0;

-- Check: freight_value >= 0
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'freight_non_negative',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'freight_value < 0'
FROM fct_order_items WHERE freight_value < 0;

-- Check: total_item_value = price + freight_value
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'total_item_value_integrity',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'total_item_value != price + freight_value'
FROM fct_order_items
WHERE ABS(total_item_value - (price + freight_value)) > 0.01;

-- Check: FK integrity — customer_key exists in dim_customer
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'fk_customer_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'customer_key not found in dim_customer'
FROM fct_order_items fi
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customer dc WHERE dc.customer_key = fi.customer_key
);

-- Check: FK integrity — seller_key exists in dim_seller
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'fk_seller_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'seller_key not found in dim_seller'
FROM fct_order_items fi
WHERE NOT EXISTS (
    SELECT 1 FROM dim_seller ds WHERE ds.seller_key = fi.seller_key
);

-- Check: FK integrity — product_key exists in dim_product
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'fk_product_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'product_key not found in dim_product'
FROM fct_order_items fi
WHERE NOT EXISTS (
    SELECT 1 FROM dim_product dp WHERE dp.product_key = fi.product_key
);

-- Check: order_date_key exists in dim_date
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_items', 'fk_order_date_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'order_date_key not found in dim_date'
FROM fct_order_items fi
WHERE NOT EXISTS (
    SELECT 1 FROM dim_date d WHERE d.date_key = fi.order_date_key
);

-- ─── fct_order_lifecycle ──────────────────────────────────────

-- Check: unique order_id (natural key)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_lifecycle', 'unique_order_id',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'Duplicate order_id'
FROM (SELECT order_id FROM fct_order_lifecycle GROUP BY order_id HAVING COUNT(*) > 1);

-- Check: vs_estimated_days within plausible range (-365 to 365)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_lifecycle', 'vs_estimated_days_range',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'vs_estimated_days outside [-365, 365]'
FROM fct_order_lifecycle
WHERE vs_estimated_days IS NOT NULL
  AND (vs_estimated_days < -365 OR vs_estimated_days > 365);

-- Check: no negative approval_delay_hours
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_lifecycle', 'approval_delay_non_negative',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'approval_delay_hours < 0 (approved before purchase)'
FROM fct_order_lifecycle
WHERE approval_delay_hours IS NOT NULL AND approval_delay_hours < 0;

-- Check: FK — customer_key exists in dim_customer
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_order_lifecycle', 'fk_customer_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'customer_key not found in dim_customer'
FROM fct_order_lifecycle fl
WHERE NOT EXISTS (
    SELECT 1 FROM dim_customer dc WHERE dc.customer_key = fl.customer_key
);

-- ─── fct_seller_monthly_snapshot ─────────────────────────────

-- Check: unique natural key (seller_key, snapshot_year_month)
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_seller_monthly_snapshot', 'unique_natural_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'Duplicate (seller_key, snapshot_year_month)'
FROM (
    SELECT seller_key, snapshot_year_month
    FROM fct_seller_monthly_snapshot
    GROUP BY seller_key, snapshot_year_month HAVING COUNT(*) > 1
);

-- Check: total_revenue >= 0
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_seller_monthly_snapshot', 'revenue_non_negative',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'total_revenue < 0'
FROM fct_seller_monthly_snapshot WHERE total_revenue < 0;

-- Check: avg_review_score between 1 and 5 where not null
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_seller_monthly_snapshot', 'avg_review_score_range',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'avg_review_score outside [1, 5]'
FROM fct_seller_monthly_snapshot
WHERE avg_review_score IS NOT NULL
  AND (avg_review_score < 1 OR avg_review_score > 5);

-- Check: FK — seller_key exists in dim_seller
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_seller_monthly_snapshot', 'fk_seller_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'seller_key not found in dim_seller'
FROM fct_seller_monthly_snapshot fs
WHERE NOT EXISTS (
    SELECT 1 FROM dim_seller ds WHERE ds.seller_key = fs.seller_key
);

-- Check: snapshot_month_key exists in dim_date
INSERT INTO dqc_results (layer, table_name, check_name, status, failed_count, note)
SELECT 'fct', 'fct_seller_monthly_snapshot', 'fk_snapshot_month_key',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    COUNT(*), 'snapshot_month_key not found in dim_date'
FROM fct_seller_monthly_snapshot fs
WHERE NOT EXISTS (
    SELECT 1 FROM dim_date d WHERE d.date_key = fs.snapshot_month_key
);