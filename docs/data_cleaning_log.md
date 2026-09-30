# Data Cleaning Log

Every decision made between the nine raw CSVs and the database, with the evidence behind it. Implemented in `src/load_data.py`.

**Starting point:** nine CSV files, ~1.45M rows total.
**End point:** nine tables, 99,441 orders, verified against the source on every load.

---

## 1. Geolocation — 1,000,163 GPS pings collapsed to 19,010 ZIP prefixes

The geolocation file holds roughly 53 GPS readings per Brazilian ZIP prefix, because every customer and seller address in that prefix contributed a point. Loaded as-is, joining it to any other table would multiply rows 53-fold.

Each prefix was collapsed to one representative point:

- **Coordinates: median, not mean.** A single mistyped coordinate would drag a mean hundreds of miles; the median ignores it.
- **City and state: the most frequent spelling.** City names within one prefix vary by accent and abbreviation (`sao paulo`, `são paulo`, `sp`). Taking the mode gives the common spelling rather than an arbitrary first row.
- **42 points dropped** for falling outside Brazil's mainland bounding box (latitude −34 to 6, longitude −74 to −34). One had a longitude of +121, which is in China.

The schema enforces the bounding box with a `CHECK` constraint, so a corrupt point can't be loaded in future.

## 2. `review_id` is not a primary key

789 review IDs appear on two or three **different** orders, 814 duplicate rows in total. These are not duplicate records: the order IDs differ, so the same review is linked to several orders.

The fix is the composite key `(review_id, order_id)`, which the loader asserts is unique. Using `review_id` alone as the primary key would have rejected 814 valid rows.

This is a good illustration of why you check key uniqueness instead of assuming a column named `..._id` is unique.

## 3. 547 orders have more than one review

Some customers reviewed the same order two or three times, days apart, occasionally with different scores.

Order-level analysis needs exactly one review per order, so `v_order_primary_review` keeps the **earliest** review, as the reaction closest to delivery. Ties on the same date are broken by `review_id`, which matters more than it looks: without a deterministic tiebreak the view could return a different row between runs, and the same query would give slightly different answers on different days.

The loader verifies that the view returns exactly one row per order.

## 4. Byte-order mark in the translation file

`product_category_name_translation.csv` begins with a UTF-8 byte-order mark, an invisible marker some tools write at the start of a file. Read with default settings, the first column is named `﻿product_category_name` rather than `product_category_name`, and every join on that column silently returns nothing.

Reading with `encoding='utf-8-sig'` strips it. This is the same class of bug as the pandas `None` trap: an invisible default that produces a wrong answer rather than an error.

## 5. Two product categories missing from the translation file

`pc_gamer` and `portateis_cozinha_e_preparadores_de_alimentos` appear on products but have no English translation.

Dropping those products would silently lose sales data, so both categories are added with a readable fallback (`pc gamer (untranslated)`), and the fallback is labeled so nobody mistakes it for an official translation. 610 products have no category at all in the source; those keep a `NULL` category and appear as `uncategorized` in category queries.

## 6. Payments and items are at different grains — aggregate before joining

`order_items` has one row per line item and `order_payments` one row per payment method. 2,961 orders were paid with more than one method (typically a voucher plus a card).

Joining both to `orders` directly produces a **fan-out**: an order with 3 items and 2 payment methods becomes 6 rows, and both revenue and payment totals inflate. `v_order_value` aggregates each side in its own subquery *before* joining.

The loader verifies this: the payment total through the view must equal the raw sum from the source file. It does, to the cent ($16,008,872.12).

## 7. Timestamp anomalies — flagged, not deleted

1,373 delivered orders (1.4%) have timestamps out of order, nearly all of them shipped to the carrier before payment was approved. That may be real — a seller shipping before the payment cleared — but it produces negative stage durations, which are not measurable times.

Rather than delete these orders, `v_order_fulfillment` flags them with `has_timestamp_anomaly`. Stage-duration queries exclude them and report how many were excluded; lateness and review analysis keeps them, since delivery date and review score are still valid. **Flagging rather than deleting keeps the decision visible** and lets each query make its own choice.

## 8. Lateness measured in calendar days, not elapsed hours

Olist promises a delivery **date**, not a time. An order promised for the 18th and delivered at 9pm on the 18th arrived as promised.

Comparing raw timestamps would score that order 0.9 days late. So both dates are truncated with `DATE()` before subtracting:

```sql
CAST(JULIANDAY(DATE(delivered_to_customer_at))
   - JULIANDAY(DATE(estimated_delivery_date)) AS INTEGER) AS days_late
```

Negative means early, 0 means on the promised day, positive means late. This definition matches the promise the customer was actually given.

## 9. Orders excluded from the fulfillment analysis

Of 99,441 orders, **96,455** are in `v_order_fulfillment`. The excluded 2,986 are:

| Reason | Orders |
|---|---|
| Not delivered (canceled, unavailable, shipped, processing, …) | 2,963 |
| Delivered but missing a stage timestamp | 23 |

A stage can't be timed if one of its endpoints is missing, and an undelivered order has no delivery date to compare against the promise. 99.3% of the remaining orders have a review, so review-based findings cover nearly the whole set.

775 orders have no line items at all; 767 of those are `unavailable` or `canceled`, which is consistent with orders that were never fulfilled. `v_order_value` uses `LEFT JOIN` with `COALESCE(..., 0)` so those orders keep a row with zero value instead of disappearing.

## 10. Smaller fixes

- **Column typo in the source:** `product_name_lenght` and `product_description_lenght` are renamed to `..._length`.
- **ZIP prefixes zero-padded** to five characters and stored as text. Read as numbers, `01037` becomes `1037` and stops matching.
- **Timestamps to ISO-8601 text.** SQLite has no datetime type; its date functions read this format.
- **Columns renamed** to shorter, consistent names (`order_purchase_timestamp` → `purchased_at`).

---

## Verification (runs automatically at the end of every load)

- Row counts for all nine tables match the cleaned DataFrames.
- `PRAGMA foreign_key_check` reports no violations across all six foreign keys.
- `v_order_primary_review` returns exactly one row per order.
- Payment totals through `v_order_value` match the raw source sum, proving no fan-out.
- SQL window-function medians and 90th percentiles were cross-checked against pandas for all three pipeline stages: every value matches.
