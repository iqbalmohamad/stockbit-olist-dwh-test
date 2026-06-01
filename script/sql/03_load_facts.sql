-- ============================================================
-- Load Facts — IDEMPOTENT
-- Strategy:
--   fct_order_items          : DELETE on natural key (order_id)
--                              + INSERT fresh
--   fct_order_lifecycle      : DELETE on natural key (order_id)
--                              + INSERT fresh
--   fct_seller_monthly_snapshot: DELETE on natural key
--                              (seller_key, snapshot_year_month)
--                              + INSERT fresh
-- ============================================================

-- ─── 1. fct_order_items ──────────────────────────────────────
-- Natural key: (order_id, order_item_id)
-- Delete all order_ids present in source, then reload.

DELETE FROM fct_order_items
WHERE order_id IN (SELECT DISTINCT order_id FROM raw_order_items);

INSERT INTO fct_order_items (
    order_date_key, customer_key, seller_key, product_key, order_flags_key,
    order_id, order_item_id,
    price, freight_value, total_item_value,
    shipping_limit_date, order_purchase_date
)
WITH
stg_orders AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        TRY_CAST(order_purchase_timestamp      AS TIMESTAMP) AS purchase_ts,
        TRY_CAST(order_delivered_customer_date AS TIMESTAMP) AS delivered_ts,
        TRY_CAST(order_estimated_delivery_date AS TIMESTAMP) AS estimated_ts
    FROM raw_orders
),
stg_items AS (
    SELECT
        order_id,
        TRY_CAST(order_item_id       AS INTEGER)      AS order_item_id,
        product_id,
        seller_id,
        TRY_CAST(shipping_limit_date AS TIMESTAMP)    AS shipping_limit_date,
        TRY_CAST(price               AS DECIMAL(10,2)) AS price,
        TRY_CAST(freight_value       AS DECIMAL(10,2)) AS freight_value
    FROM raw_order_items
    -- Cleansing: 1 row has price='empattigakomakosongkosong' (Indonesian text for 43.00)
    WHERE TRY_CAST(price         AS DECIMAL(10,2)) IS NOT NULL
      AND TRY_CAST(freight_value AS DECIMAL(10,2)) IS NOT NULL
),
items_per_order AS (
    SELECT order_id, COUNT(*) > 1 AS is_multi_item
    FROM stg_items
    GROUP BY order_id
),
customer_lookup AS (
    SELECT customer_id, customer_unique_id
    FROM raw_customers
)
SELECT
    CAST(strftime(purchase_ts::DATE, '%Y%m%d') AS INTEGER) AS order_date_key,
    dc.customer_key,
    ds.seller_key,
    dp.product_key,
    dof.order_flags_key,
    i.order_id,
    i.order_item_id,
    i.price,
    i.freight_value,
    i.price + i.freight_value                              AS total_item_value,
    i.shipping_limit_date,
    purchase_ts::DATE                                      AS order_purchase_date
FROM stg_items i
JOIN stg_orders      o   ON i.order_id  = o.order_id
JOIN customer_lookup cl  ON o.customer_id = cl.customer_id
JOIN dim_customer    dc  ON cl.customer_unique_id = dc.customer_unique_id
JOIN dim_seller      ds  ON i.seller_id  = ds.seller_id
JOIN dim_product     dp  ON i.product_id = dp.product_id
JOIN items_per_order ipo ON i.order_id   = ipo.order_id
LEFT JOIN dim_order_flags dof
    ON  dof.order_status     = o.order_status
    AND dof.is_late_delivery = (
            o.delivered_ts IS NOT NULL
            AND o.delivered_ts > o.estimated_ts
        )
    AND dof.is_multi_item = ipo.is_multi_item
WHERE o.purchase_ts IS NOT NULL;

-- ─── 2. fct_order_lifecycle ───────────────────────────────────
-- Natural key: order_id (UNIQUE constraint in DDL)
-- Delete all order_ids present in source, then reload.

DELETE FROM fct_order_lifecycle
WHERE order_id IN (SELECT DISTINCT order_id FROM raw_orders);

INSERT INTO fct_order_lifecycle (
    purchase_date_key, approved_date_key, carrier_date_key,
    delivered_date_key, estimated_date_key,
    customer_key, order_flags_key, order_id,
    approval_delay_hours, carrier_pickup_delay_hours,
    delivery_delay_days, vs_estimated_days,
    order_purchase_date
)
WITH
stg_orders AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        TRY_CAST(order_purchase_timestamp      AS TIMESTAMP) AS purchase_ts,
        TRY_CAST(order_approved_at             AS TIMESTAMP) AS approved_ts,
        TRY_CAST(order_delivered_carrier_date  AS TIMESTAMP) AS carrier_ts,
        TRY_CAST(order_delivered_customer_date AS TIMESTAMP) AS delivered_ts,
        TRY_CAST(order_estimated_delivery_date AS TIMESTAMP) AS estimated_ts
    FROM raw_orders
),
items_per_order AS (
    SELECT order_id, COUNT(*) > 1 AS is_multi_item
    FROM raw_order_items
    GROUP BY order_id
),
customer_lookup AS (
    SELECT customer_id, customer_unique_id
    FROM raw_customers
)
SELECT
    CAST(strftime(purchase_ts::DATE, '%Y%m%d') AS INTEGER)              AS purchase_date_key,
    CASE WHEN approved_ts IS NOT NULL
         THEN CAST(strftime(approved_ts::DATE,  '%Y%m%d') AS INTEGER)  END AS approved_date_key,
    CASE WHEN carrier_ts IS NOT NULL
         THEN CAST(strftime(carrier_ts::DATE,   '%Y%m%d') AS INTEGER)  END AS carrier_date_key,
    CASE WHEN delivered_ts IS NOT NULL
         THEN CAST(strftime(delivered_ts::DATE, '%Y%m%d') AS INTEGER)  END AS delivered_date_key,
    CASE WHEN estimated_ts IS NOT NULL
         THEN CAST(strftime(estimated_ts::DATE, '%Y%m%d') AS INTEGER)  END AS estimated_date_key,
    dc.customer_key,
    dof.order_flags_key,
    o.order_id,
    CASE WHEN o.approved_ts IS NOT NULL
         THEN DATEDIFF('minute', o.purchase_ts, o.approved_ts) / 60.0
    END AS approval_delay_hours,
    CASE WHEN o.carrier_ts IS NOT NULL AND o.approved_ts IS NOT NULL
         THEN DATEDIFF('minute', o.approved_ts, o.carrier_ts) / 60.0
    END AS carrier_pickup_delay_hours,
    CASE WHEN o.delivered_ts IS NOT NULL AND o.carrier_ts IS NOT NULL
         THEN DATEDIFF('minute', o.carrier_ts, o.delivered_ts) / 1440.0
    END AS delivery_delay_days,
    CASE WHEN o.delivered_ts IS NOT NULL AND o.estimated_ts IS NOT NULL
         THEN DATEDIFF('minute', o.estimated_ts, o.delivered_ts) / 1440.0
    END AS vs_estimated_days,
    o.purchase_ts::DATE AS order_purchase_date
FROM stg_orders o
JOIN customer_lookup cl  ON o.customer_id = cl.customer_id
JOIN dim_customer    dc  ON cl.customer_unique_id = dc.customer_unique_id
LEFT JOIN items_per_order ipo ON o.order_id = ipo.order_id
LEFT JOIN dim_order_flags dof
    ON  dof.order_status     = o.order_status
    AND dof.is_late_delivery = (
            o.delivered_ts IS NOT NULL
            AND o.delivered_ts > o.estimated_ts
        )
    AND dof.is_multi_item = COALESCE(ipo.is_multi_item, FALSE)
WHERE o.purchase_ts IS NOT NULL;

-- ─── 3. fct_seller_monthly_snapshot ──────────────────────────
-- Natural key: (seller_key, snapshot_year_month)
-- Delete months present in source, then reload.

DELETE FROM fct_seller_monthly_snapshot
WHERE snapshot_year_month IN (
    SELECT DISTINCT strftime(TRY_CAST(order_purchase_timestamp AS DATE), '%Y-%m')
    FROM raw_orders
    WHERE TRY_CAST(order_purchase_timestamp AS TIMESTAMP) IS NOT NULL
);

INSERT INTO fct_seller_monthly_snapshot (
    snapshot_month_key, seller_key,
    total_orders, total_items_sold,
    total_revenue, total_freight,
    avg_review_score, avg_delivery_delay_days,
    snapshot_year_month
)
WITH
stg_orders AS (
    SELECT
        order_id,
        TRY_CAST(order_purchase_timestamp      AS TIMESTAMP) AS purchase_ts,
        TRY_CAST(order_delivered_customer_date AS TIMESTAMP) AS delivered_ts,
        TRY_CAST(order_estimated_delivery_date AS TIMESTAMP) AS estimated_ts
    FROM raw_orders
    WHERE TRY_CAST(order_purchase_timestamp AS TIMESTAMP) IS NOT NULL
),
stg_items AS (
    SELECT
        order_id,
        seller_id,
        TRY_CAST(price         AS DECIMAL(10,2)) AS price,
        TRY_CAST(freight_value AS DECIMAL(10,2)) AS freight_value
    FROM raw_order_items
    WHERE TRY_CAST(price         AS DECIMAL(10,2)) IS NOT NULL
      AND TRY_CAST(freight_value AS DECIMAL(10,2)) IS NOT NULL
),
stg_reviews AS (
    SELECT order_id, TRY_CAST(review_score AS INTEGER) AS review_score
    FROM raw_reviews
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY review_id
        ORDER BY TRY_CAST(review_answer_timestamp AS TIMESTAMP) DESC NULLS LAST
    ) = 1
),
base AS (
    SELECT
        ds.seller_key,
        DATE_TRUNC('month', o.purchase_ts::DATE)   AS snap_month,
        strftime(o.purchase_ts::DATE, '%Y-%m')     AS snapshot_year_month,
        i.order_id,
        i.price,
        i.freight_value,
        r.review_score,
        CASE
            WHEN o.delivered_ts IS NOT NULL AND o.estimated_ts IS NOT NULL
            THEN DATEDIFF('minute', o.estimated_ts, o.delivered_ts) / 1440.0
        END AS vs_estimated_days
    FROM stg_items i
    JOIN stg_orders   o  ON i.order_id  = o.order_id
    JOIN dim_seller   ds ON i.seller_id = ds.seller_id
    LEFT JOIN stg_reviews r ON o.order_id = r.order_id
)
SELECT
    CAST(strftime(snap_month::DATE, '%Y%m%d') AS INTEGER) AS snapshot_month_key,
    seller_key,
    COUNT(DISTINCT order_id)           AS total_orders,
    COUNT(*)                           AS total_items_sold,
    SUM(price)                         AS total_revenue,
    SUM(freight_value)                 AS total_freight,
    AVG(review_score::DECIMAL)         AS avg_review_score,
    AVG(vs_estimated_days)             AS avg_delivery_delay_days,
    snapshot_year_month
FROM base
GROUP BY seller_key, snap_month, snapshot_year_month;