-- ============================================================
-- Load Dimensions — IDEMPOTENT
-- Strategy:
--   Static tables  : DELETE FROM + INSERT (rebuild each run)
--   SCD Type 1 dims: MERGE (upsert on business key)
--   SCD Type 2 hist: 3-step — (1) UPDATE SCD1 cols across all rows
--                              (2) CLOSE changed current records
--                              (3) INSERT new current records
-- ============================================================

-- ─── 1. dim_date ─────────────────────────────────────────────
INSERT OR IGNORE INTO dim_date
SELECT
    CAST(strftime(d, '%Y%m%d') AS INTEGER) AS date_key,
    d::DATE                                 AS full_date,
    YEAR(d)                                 AS year,
    QUARTER(d)                              AS quarter,
    MONTH(d)                                AS month,
    strftime(d, '%B')                       AS month_name,
    WEEK(d)                                 AS week_of_year,
    DAYOFWEEK(d)                            AS day_of_week,
    strftime(d, '%A')                       AS day_name,
    DAYOFWEEK(d) IN (0, 6)                 AS is_weekend
FROM (
    SELECT UNNEST(
        generate_series(DATE '2015-01-01', DATE '2022-12-31', INTERVAL '1 day')
    )::DATE AS d
) dates;

-- ─── 2. dim_payment_type ─────────────────────────────────────
INSERT OR IGNORE INTO dim_payment_type (payment_type_key, payment_type, payment_type_desc)
VALUES
    (1, 'credit_card', 'Credit Card'),
    (2, 'boleto',      'Boleto Bancário'),
    (3, 'voucher',     'Voucher / Gift Card'),
    (4, 'debit_card',  'Debit Card'),
    (5, 'not_defined', 'Not Defined / Unknown');

-- ─── 3. dim_order_flags (junk) ───────────────────────────────
INSERT OR IGNORE INTO dim_order_flags (order_status, is_late_delivery, is_multi_item)
SELECT s.status, l.is_late, m.is_multi
FROM (
    VALUES ('delivered'), ('shipped'), ('canceled'), ('unavailable'),
           ('invoiced'), ('processing'), ('created'), ('approved')
) s(status)
CROSS JOIN (VALUES (TRUE), (FALSE)) l(is_late)
CROSS JOIN (VALUES (TRUE), (FALSE)) m(is_multi);

-- ─── 4. dim_customer — SCD Type 1 MERGE ──────────────────────
MERGE INTO dim_customer t
USING (
    SELECT
        customer_unique_id,
        customer_id,
        TRIM(customer_zip_code_prefix) AS customer_zip_code,
        LOWER(TRIM(customer_city))     AS customer_city,
        UPPER(TRIM(customer_state))    AS customer_state
    FROM raw_customers
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY customer_id) = 1
) s ON t.customer_unique_id = s.customer_unique_id
WHEN MATCHED THEN UPDATE SET
    customer_id       = s.customer_id,
    customer_zip_code = s.customer_zip_code,
    customer_city     = s.customer_city,
    customer_state    = s.customer_state
WHEN NOT MATCHED THEN INSERT (customer_unique_id, customer_id, customer_zip_code, customer_city, customer_state)
VALUES (s.customer_unique_id, s.customer_id, s.customer_zip_code, s.customer_city, s.customer_state);

-- ─── 5. dim_seller — SCD Type 1 MERGE ────────────────────────
MERGE INTO dim_seller t
USING (
    SELECT
        seller_id,
        TRIM(seller_zip_code_prefix)   AS seller_zip_code,
        LOWER(TRIM(seller_city))       AS seller_city,
        UPPER(TRIM(seller_state))      AS seller_state
    FROM raw_sellers
) s ON t.seller_id = s.seller_id
WHEN MATCHED THEN UPDATE SET
    seller_zip_code = s.seller_zip_code,
    seller_city     = s.seller_city,
    seller_state    = s.seller_state
WHEN NOT MATCHED THEN INSERT (seller_id, seller_zip_code, seller_city, seller_state)
VALUES (s.seller_id, s.seller_zip_code, s.seller_city, s.seller_state);

-- ─── 6. dim_product — SCD Type 1 MERGE ───────────────────────
MERGE INTO dim_product t
USING (
    WITH stg_cat AS (
        SELECT product_category_name,
               LOWER(TRIM(product_category_name_english)) AS category_name_english
        FROM raw_category_translation
    )
    SELECT
        p.product_id,
        COALESCE(p.product_category_name, 'unknown')     AS category_name,
        COALESCE(c.category_name_english,  'unknown')    AS category_name_english,
        TRY_CAST(p.product_name_lenght        AS INTEGER) AS product_name_length,
        TRY_CAST(p.product_description_lenght AS INTEGER) AS product_description_length,
        TRY_CAST(p.product_photos_qty         AS INTEGER) AS product_photos_qty,
        TRY_CAST(p.product_weight_g           AS INTEGER) AS product_weight_g,
        TRY_CAST(p.product_length_cm          AS INTEGER) AS product_length_cm,
        TRY_CAST(p.product_height_cm          AS INTEGER) AS product_height_cm,
        TRY_CAST(p.product_width_cm           AS INTEGER) AS product_width_cm
    FROM raw_products p
    LEFT JOIN stg_cat c ON p.product_category_name = c.product_category_name
) s ON t.product_id = s.product_id
WHEN MATCHED THEN UPDATE SET
    category_name              = s.category_name,
    category_name_english      = s.category_name_english,
    product_name_length        = s.product_name_length,
    product_description_length = s.product_description_length,
    product_photos_qty         = s.product_photos_qty,
    product_weight_g           = s.product_weight_g,
    product_length_cm          = s.product_length_cm,
    product_height_cm          = s.product_height_cm,
    product_width_cm           = s.product_width_cm
WHEN NOT MATCHED THEN INSERT (
    product_id, category_name, category_name_english,
    product_name_length, product_description_length, product_photos_qty,
    product_weight_g, product_length_cm, product_height_cm, product_width_cm
) VALUES (
    s.product_id, s.category_name, s.category_name_english,
    s.product_name_length, s.product_description_length, s.product_photos_qty,
    s.product_weight_g, s.product_length_cm, s.product_height_cm, s.product_width_cm
);

-- ─── 7. dim_seller_hist — SCD Type 2 (3-step idempotent) ─────

-- Step 7a: SCD Type 1 — update zip_code across ALL rows for changed sellers
UPDATE dim_seller_hist h
SET seller_zip_code = s.seller_zip_code
FROM (
    SELECT seller_id, TRIM(seller_zip_code_prefix) AS seller_zip_code
    FROM raw_sellers
) s
WHERE h.seller_id = s.seller_id
  AND h.seller_zip_code IS DISTINCT FROM s.seller_zip_code;

-- Step 7b: SCD Type 2 — close current records where city or state changed
UPDATE dim_seller_hist h
SET is_current   = FALSE,
    scd_end_date = CURRENT_DATE - INTERVAL '1 day'
FROM (
    SELECT seller_id,
           LOWER(TRIM(seller_city))  AS seller_city,
           UPPER(TRIM(seller_state)) AS seller_state
    FROM raw_sellers
) s
WHERE h.seller_id  = s.seller_id
  AND h.is_current = TRUE
  AND (h.seller_city  IS DISTINCT FROM s.seller_city
    OR h.seller_state IS DISTINCT FROM s.seller_state);

-- Step 7c: SCD Type 2 — insert new current record for sellers with no active row
INSERT INTO dim_seller_hist (seller_id, seller_zip_code, seller_city, seller_state, scd_start_date, scd_end_date, is_current)
SELECT
    s.seller_id,
    TRIM(s.seller_zip_code_prefix)   AS seller_zip_code,
    LOWER(TRIM(s.seller_city))       AS seller_city,
    UPPER(TRIM(s.seller_state))      AS seller_state,
    CURRENT_DATE                     AS scd_start_date,
    NULL                             AS scd_end_date,
    TRUE                             AS is_current
FROM raw_sellers s
WHERE NOT EXISTS (
    SELECT 1 FROM dim_seller_hist h
    WHERE h.seller_id  = s.seller_id
      AND h.is_current = TRUE
);

-- ─── 8. dim_product_hist — SCD Type 2 (3-step idempotent) ────

-- Step 8a: SCD Type 1 — update physical dimensions across ALL rows
UPDATE dim_product_hist h
SET product_weight_g  = s.product_weight_g,
    product_length_cm = s.product_length_cm,
    product_height_cm = s.product_height_cm,
    product_width_cm  = s.product_width_cm
FROM (
    SELECT product_id,
           TRY_CAST(product_weight_g  AS INTEGER) AS product_weight_g,
           TRY_CAST(product_length_cm AS INTEGER) AS product_length_cm,
           TRY_CAST(product_height_cm AS INTEGER) AS product_height_cm,
           TRY_CAST(product_width_cm  AS INTEGER) AS product_width_cm
    FROM raw_products
) s
WHERE h.product_id = s.product_id
  AND (h.product_weight_g  IS DISTINCT FROM s.product_weight_g
    OR h.product_length_cm IS DISTINCT FROM s.product_length_cm
    OR h.product_height_cm IS DISTINCT FROM s.product_height_cm
    OR h.product_width_cm  IS DISTINCT FROM s.product_width_cm);

-- Step 8b: SCD Type 2 — close current records where category changed
UPDATE dim_product_hist h
SET is_current   = FALSE,
    scd_end_date = CURRENT_DATE - INTERVAL '1 day'
FROM (
    WITH stg_cat AS (
        SELECT product_category_name,
               LOWER(TRIM(product_category_name_english)) AS category_name_english
        FROM raw_category_translation
    )
    SELECT
        p.product_id,
        COALESCE(p.product_category_name, 'unknown')  AS category_name,
        COALESCE(c.category_name_english,  'unknown') AS category_name_english
    FROM raw_products p
    LEFT JOIN stg_cat c ON p.product_category_name = c.product_category_name
) s
WHERE h.product_id  = s.product_id
  AND h.is_current  = TRUE
  AND (h.category_name         IS DISTINCT FROM s.category_name
    OR h.category_name_english IS DISTINCT FROM s.category_name_english);

-- Step 8c: SCD Type 2 — insert new current record for products with no active row
INSERT INTO dim_product_hist (
    product_id, category_name, category_name_english,
    product_weight_g, product_length_cm, product_height_cm, product_width_cm,
    scd_start_date, scd_end_date, is_current
)
WITH stg_cat AS (
    SELECT product_category_name,
           LOWER(TRIM(product_category_name_english)) AS category_name_english
    FROM raw_category_translation
)
SELECT
    p.product_id,
    COALESCE(p.product_category_name, 'unknown')     AS category_name,
    COALESCE(c.category_name_english,  'unknown')    AS category_name_english,
    TRY_CAST(p.product_weight_g  AS INTEGER)          AS product_weight_g,
    TRY_CAST(p.product_length_cm AS INTEGER)          AS product_length_cm,
    TRY_CAST(p.product_height_cm AS INTEGER)          AS product_height_cm,
    TRY_CAST(p.product_width_cm  AS INTEGER)          AS product_width_cm,
    CURRENT_DATE                                      AS scd_start_date,
    NULL                                              AS scd_end_date,
    TRUE                                              AS is_current
FROM raw_products p
LEFT JOIN stg_cat c ON p.product_category_name = c.product_category_name
WHERE NOT EXISTS (
    SELECT 1 FROM dim_product_hist h
    WHERE h.product_id = p.product_id AND h.is_current = TRUE
);