-- =====================================================================
-- 03_analysis.sql
-- Each query starts with a "-- name:" line. run_analysis.py splits on
-- those lines, runs each query, prints it, and writes output/<name>.csv
--
-- SQLite has no MEDIAN or PERCENTILE function, so both are built with
-- window functions:
--   median = average of the middle value(s) after ranking
--   p90    = nearest-rank method: the smallest value at rank >= ceil(0.9n),
--            where ceil(0.9n) is computed as (9n + 9) / 10 using SQLite's
--            integer division
-- =====================================================================


-- name: pipeline_stage_durations
-- How long does each stage of fulfillment take?
-- Median shows the typical order; p90 shows the bad tail.
WITH ranked AS (
    SELECT
        stage_order, stage, hours,
        ROW_NUMBER() OVER (PARTITION BY stage_order ORDER BY hours) AS rn,
        COUNT(*)     OVER (PARTITION BY stage_order)                AS n
    FROM v_stage_durations
)
SELECT
    stage_order,
    stage,
    MAX(n)                                                              AS orders,
    ROUND(AVG(CASE WHEN rn IN ((n+1)/2, (n+2)/2) THEN hours END), 1)    AS median_hours,
    ROUND(MIN(CASE WHEN rn >= (9*n + 9)/10       THEN hours END), 1)    AS p90_hours,
    ROUND(AVG(hours), 1)                                                AS mean_hours
FROM ranked
GROUP BY stage_order, stage
ORDER BY stage_order;


-- name: delivery_promise_vs_review
-- The core business question: what does a missed delivery promise cost
-- in customer satisfaction?
SELECT
    CASE
        WHEN days_late <  0 THEN '1. Early'
        WHEN days_late =  0 THEN '2. On the promised day'
        WHEN days_late <= 3 THEN '3. 1-3 days late'
        WHEN days_late <= 7 THEN '4. 4-7 days late'
        WHEN days_late <= 14 THEN '5. 8-14 days late'
        ELSE                     '6. 15+ days late'
    END                                                          AS delivery_outcome,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(review_score), 2)                                  AS avg_review_score,
    ROUND(100.0 * SUM(CASE WHEN review_score = 1 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_one_star,
    ROUND(100.0 * SUM(CASE WHEN review_score >= 4 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_four_or_five
FROM v_order_fulfillment
WHERE review_score IS NOT NULL
GROUP BY delivery_outcome
ORDER BY delivery_outcome;


-- name: stage_delay_attribution
-- Which stage actually differs between on-time and late orders?
-- This separates the stage that is merely LONG from the stage that is
-- long specifically when things go wrong.
WITH ranked AS (
    SELECT
        stage_order, stage, is_late, hours,
        ROW_NUMBER() OVER (PARTITION BY stage_order, is_late ORDER BY hours) AS rn,
        COUNT(*)     OVER (PARTITION BY stage_order, is_late)                AS n
    FROM v_stage_durations
),
medians AS (
    SELECT stage_order, stage, is_late,
           AVG(CASE WHEN rn IN ((n+1)/2, (n+2)/2) THEN hours END) AS median_hours
    FROM ranked
    GROUP BY stage_order, stage, is_late
)
SELECT
    stage_order,
    stage,
    ROUND(MAX(CASE WHEN is_late = 0 THEN median_hours END), 1) AS median_hrs_on_time,
    ROUND(MAX(CASE WHEN is_late = 1 THEN median_hours END), 1) AS median_hrs_late,
    ROUND(MAX(CASE WHEN is_late = 1 THEN median_hours END)
        - MAX(CASE WHEN is_late = 0 THEN median_hours END), 1) AS extra_hours_when_late
FROM medians
GROUP BY stage_order, stage
ORDER BY stage_order;


-- name: promise_buffer
-- Olist promises a delivery date at checkout. How much slack is in that
-- promise, and does a longer promise actually protect against lateness?
WITH bucketed AS (
    SELECT
        CASE
            WHEN promised_days <= 10 THEN '1. <= 10 days promised'
            WHEN promised_days <= 20 THEN '2. 11-20 days'
            WHEN promised_days <= 30 THEN '3. 21-30 days'
            ELSE                          '4. 30+ days'
        END                                  AS promise_window,
        is_late,
        days_late,
        review_score
    FROM v_order_fulfillment
)
SELECT
    promise_window,
    COUNT(*)                              AS orders,
    ROUND(100.0 * SUM(is_late) / COUNT(*), 1) AS late_pct,
    ROUND(AVG(-days_late), 1)             AS avg_days_early,
    ROUND(AVG(review_score), 2)           AS avg_review_score
FROM bucketed
GROUP BY promise_window
ORDER BY promise_window;


-- name: seller_scorecard
-- Sellers ranked by late-delivery rate, limited to those with enough
-- volume for the rate to mean anything. A seller with 3 orders can show
-- 33% late from a single incident.
SELECT
    seller_id,
    seller_state,
    delivered_orders,
    late_pct,
    ROUND(avg_hrs_to_handoff, 1) AS avg_hrs_to_handoff,
    avg_review_score,
    ROUND(revenue, 0)            AS revenue
FROM v_seller_performance
WHERE delivered_orders >= 50
ORDER BY late_pct DESC;


-- name: seller_concentration
-- How concentrated is the late-delivery problem? If a small share of
-- sellers causes a large share of late orders, seller-level intervention
-- is worth more than a broad process change.
WITH sized AS (
    SELECT seller_id, delivered_orders, late_pct,
           delivered_orders * late_pct / 100.0 AS late_orders
    FROM v_seller_performance
    WHERE delivered_orders >= 50
),
decile AS (
    SELECT *,
           NTILE(10) OVER (ORDER BY late_pct DESC) AS late_rate_decile
    FROM sized
)
SELECT
    late_rate_decile,
    COUNT(*)                     AS sellers,
    SUM(delivered_orders)        AS orders,
    ROUND(SUM(late_orders), 0)   AS late_orders,
    ROUND(100.0 * SUM(late_orders) / SUM(SUM(late_orders)) OVER (), 1) AS pct_of_all_late_orders
FROM decile
GROUP BY late_rate_decile
ORDER BY late_rate_decile;


-- name: category_performance
-- Late rate by product category, using the English translation.
-- An order counts once per category it contains.
SELECT
    COALESCE(pc.category_en, 'uncategorized')    AS category,
    COUNT(DISTINCT f.order_id)                   AS orders,
    ROUND(100.0 * SUM(f.is_late) / COUNT(*), 1)  AS late_pct,
    ROUND(AVG(f.review_score), 2)                AS avg_review_score,
    ROUND(AVG(p.weight_g), 0)                    AS avg_weight_g
FROM v_order_fulfillment      AS f
JOIN order_items              AS i  ON i.order_id   = f.order_id
JOIN products                 AS p  ON p.product_id = i.product_id
LEFT JOIN product_categories  AS pc ON pc.category_pt = p.category_pt
GROUP BY category
HAVING COUNT(DISTINCT f.order_id) >= 500
ORDER BY late_pct DESC;


-- name: state_performance
-- Late rate and transit time by destination state. Brazil is large, so
-- geography is a plausible driver of transit time.
WITH ranked AS (
    SELECT
        customer_state, is_late, review_score, hrs_in_transit,
        ROW_NUMBER() OVER (PARTITION BY customer_state ORDER BY hrs_in_transit) AS rn,
        COUNT(*)     OVER (PARTITION BY customer_state)                         AS n
    FROM v_order_fulfillment
    WHERE has_timestamp_anomaly = 0
)
SELECT
    customer_state,
    MAX(n)                                                                  AS orders,
    ROUND(100.0 * SUM(is_late) / COUNT(*), 1)                               AS late_pct,
    ROUND(AVG(CASE WHEN rn IN ((n+1)/2, (n+2)/2) THEN hrs_in_transit END) / 24.0, 1)
                                                                            AS median_transit_days,
    ROUND(AVG(review_score), 2)                                             AS avg_review_score
FROM ranked
GROUP BY customer_state
HAVING COUNT(*) >= 500
ORDER BY late_pct DESC;


-- name: monthly_trend
-- Is on-time performance improving or degrading over time?
-- Months with very low volume (the first and last partial months) are
-- excluded so the trend is not distorted by tiny samples.
SELECT
    purchase_month,
    COUNT(*)                                      AS orders,
    ROUND(100.0 * SUM(is_late) / COUNT(*), 1)     AS late_pct,
    ROUND(AVG(review_score), 2)                   AS avg_review_score,
    ROUND(AVG(hrs_total) / 24.0, 1)               AS avg_days_to_deliver
FROM v_order_fulfillment
GROUP BY purchase_month
HAVING COUNT(*) >= 500
ORDER BY purchase_month;


-- name: revenue_at_risk
-- Ties the operational problem to money: how much revenue sits in late
-- orders, and how much of it belongs to customers whose review suggests
-- they will not return.
SELECT
    CASE WHEN is_late = 1 THEN 'Late' ELSE 'On time or early' END AS delivery_outcome,
    COUNT(*)                                                      AS orders,
    ROUND(SUM(items_value), 0)                                    AS items_revenue,
    ROUND(SUM(freight_value), 0)                                  AS freight_revenue,
    ROUND(AVG(items_value), 2)                                    AS avg_order_value,
    ROUND(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1)
                                                                  AS pct_poor_review,
    ROUND(SUM(CASE WHEN review_score <= 2 THEN items_value ELSE 0 END), 0)
                                                                  AS revenue_with_poor_review
FROM v_order_fulfillment
GROUP BY is_late
ORDER BY is_late;
