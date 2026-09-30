-- =====================================================================
-- 02_views.sql
-- Reusable views. Everything in 03_analysis.sql is built on these.
-- =====================================================================


-- ---------------------------------------------------------------------
-- v_order_primary_review
-- One review per order.
--
-- 547 orders carry 2-3 reviews (a customer reviewed again days later).
-- Order-level analysis needs exactly one, so the rule is: keep the
-- EARLIEST review, because it is the reaction closest to delivery.
-- Ties on the same date are broken by review_id so the result is
-- deterministic — without that tiebreak the view could return a
-- different row between runs.
-- ---------------------------------------------------------------------
CREATE VIEW v_order_primary_review AS
WITH ranked AS (
    SELECT
        order_id,
        review_id,
        review_score,
        created_at,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY created_at, review_id
        ) AS rn
    FROM order_reviews
)
SELECT order_id, review_id, review_score, created_at
FROM ranked
WHERE rn = 1;


-- ---------------------------------------------------------------------
-- v_order_value
-- Order-level totals. Items and payments are at different grains, so
-- each is aggregated in its own subquery BEFORE being joined. Joining
-- them first would multiply rows (3 items x 2 payment methods = 6 rows)
-- and inflate every total — the classic fan-out trap.
-- ---------------------------------------------------------------------
CREATE VIEW v_order_value AS
SELECT
    o.order_id,
    COALESCE(i.item_count, 0)     AS item_count,
    COALESCE(i.seller_count, 0)   AS seller_count,
    COALESCE(i.items_value, 0)    AS items_value,
    COALESCE(i.freight_value, 0)  AS freight_value,
    p.payment_total,
    p.payment_methods,
    p.max_installments
FROM orders AS o
LEFT JOIN (
    SELECT order_id,
           COUNT(*)                   AS item_count,
           COUNT(DISTINCT seller_id)  AS seller_count,
           SUM(price)                 AS items_value,
           SUM(freight_value)         AS freight_value
    FROM order_items
    GROUP BY order_id
) AS i ON i.order_id = o.order_id
LEFT JOIN (
    SELECT order_id,
           SUM(payment_value)         AS payment_total,
           COUNT(*)                   AS payment_methods,
           MAX(payment_installments)  AS max_installments
    FROM order_payments
    GROUP BY order_id
) AS p ON p.order_id = o.order_id;


-- ---------------------------------------------------------------------
-- v_order_fulfillment
-- The central analysis view: one row per DELIVERED order, with each
-- pipeline stage measured in hours and the delivery promise scored.
--
-- Only delivered orders with a complete set of timestamps are included,
-- because a stage cannot be timed if one of its endpoints is missing.
--
-- days_late compares CALENDAR DAYS, not raw elapsed time. The promise
-- Olist makes is a date, not a time, so an order promised for the 18th
-- and delivered at 9pm on the 18th is on time, not 0.9 days late.
--   negative = early, 0 = on the promised day, positive = late
-- ---------------------------------------------------------------------
CREATE VIEW v_order_fulfillment AS
SELECT
    o.order_id,
    c.customer_unique_id,
    c.state                                AS customer_state,
    c.city                                 AS customer_city,
    o.purchased_at,
    DATE(o.purchased_at)                   AS purchase_date,
    STRFTIME('%Y-%m', o.purchased_at)      AS purchase_month,

    -- Stage durations, in hours
    (JULIANDAY(o.approved_at)              - JULIANDAY(o.purchased_at))            * 24.0 AS hrs_to_approve,
    (JULIANDAY(o.delivered_to_carrier_at)  - JULIANDAY(o.approved_at))             * 24.0 AS hrs_to_handoff,
    (JULIANDAY(o.delivered_to_customer_at) - JULIANDAY(o.delivered_to_carrier_at)) * 24.0 AS hrs_in_transit,
    (JULIANDAY(o.delivered_to_customer_at) - JULIANDAY(o.purchased_at))            * 24.0 AS hrs_total,

    -- The promise vs. the delivery, in whole calendar days
    CAST(JULIANDAY(DATE(o.delivered_to_customer_at))
       - JULIANDAY(DATE(o.estimated_delivery_date)) AS INTEGER)                    AS days_late,
    CASE WHEN DATE(o.delivered_to_customer_at) > DATE(o.estimated_delivery_date)
         THEN 1 ELSE 0 END                                                         AS is_late,

    -- How many days of buffer the promise itself contained
    CAST(JULIANDAY(DATE(o.estimated_delivery_date))
       - JULIANDAY(DATE(o.purchased_at)) AS INTEGER)                               AS promised_days,

    -- A negative stage duration means the source timestamps are out of
    -- order (e.g. shipped before payment cleared). Flagged here so
    -- duration queries can exclude these orders and say how many.
    CASE WHEN o.delivered_to_carrier_at  < o.approved_at
           OR o.delivered_to_customer_at < o.delivered_to_carrier_at
         THEN 1 ELSE 0 END                                                         AS has_timestamp_anomaly,

    v.item_count,
    v.seller_count,
    v.items_value,
    v.freight_value,
    v.payment_total,
    r.review_score
FROM orders                  AS o
JOIN customers               AS c ON c.customer_id = o.customer_id
JOIN v_order_value           AS v ON v.order_id    = o.order_id
LEFT JOIN v_order_primary_review AS r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.approved_at              IS NOT NULL
  AND o.delivered_to_carrier_at  IS NOT NULL
  AND o.delivered_to_customer_at IS NOT NULL;


-- ---------------------------------------------------------------------
-- v_stage_durations
-- Unpivots the three pipeline stages from wide to long: one row per
-- order per stage. Lets every stage be summarized with a single
-- GROUP BY instead of three near-identical queries.
--
-- Orders with out-of-order timestamps are excluded here, since a
-- negative duration is not a real measurement.
-- ---------------------------------------------------------------------
CREATE VIEW v_stage_durations AS
SELECT order_id, 1 AS stage_order, 'Payment approval' AS stage, hrs_to_approve AS hours, is_late, days_late
FROM v_order_fulfillment WHERE has_timestamp_anomaly = 0
UNION ALL
SELECT order_id, 2, 'Seller handoff', hrs_to_handoff, is_late, days_late
FROM v_order_fulfillment WHERE has_timestamp_anomaly = 0
UNION ALL
SELECT order_id, 3, 'Carrier transit', hrs_in_transit, is_late, days_late
FROM v_order_fulfillment WHERE has_timestamp_anomaly = 0;


-- ---------------------------------------------------------------------
-- v_seller_performance
-- Seller-level scorecard. A seller is credited with an order if any of
-- its line items belong to them, so a multi-seller order counts once
-- for each seller involved.
-- ---------------------------------------------------------------------
CREATE VIEW v_seller_performance AS
SELECT
    s.seller_id,
    s.state                                                 AS seller_state,
    COUNT(DISTINCT f.order_id)                              AS delivered_orders,
    ROUND(100.0 * SUM(f.is_late) / COUNT(*), 1)             AS late_pct,
    ROUND(AVG(f.hrs_to_handoff), 1)                         AS avg_hrs_to_handoff,
    ROUND(AVG(f.review_score), 2)                           AS avg_review_score,
    ROUND(SUM(i.price), 2)                                  AS revenue
FROM v_order_fulfillment AS f
JOIN order_items         AS i ON i.order_id  = f.order_id
JOIN sellers             AS s ON s.seller_id = i.seller_id
GROUP BY s.seller_id, s.state;
