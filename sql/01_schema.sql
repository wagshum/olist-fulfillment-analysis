-- =====================================================================
-- 01_schema.sql
-- Nine-table schema for the Olist Brazilian e-commerce dataset.
--
-- Unlike a flat export that has to be split up, these nine tables
-- arrived as nine separate files with real foreign keys between them.
-- The schema below just makes those relationships explicit and
-- enforceable.
--
-- Grain (what one row means) differs by table, and that matters for
-- every query written against them:
--
--   customers          one row per ORDER's customer record
--                      (customer_id is per-order; customer_unique_id
--                       is the real person across orders)
--   sellers            one row per seller
--   product_categories one row per category (Portuguese -> English)
--   products           one row per product
--   geolocation        one row per ZIP prefix (deduplicated on load)
--   orders             one row per order
--   order_items        one row per LINE ITEM (an order can have many)
--   order_payments     one row per PAYMENT METHOD used on an order
--   order_reviews      one row per review-to-order link
-- =====================================================================

PRAGMA foreign_keys = ON;

DROP VIEW  IF EXISTS v_seller_performance;
DROP VIEW  IF EXISTS v_stage_durations;
DROP VIEW  IF EXISTS v_order_fulfillment;
DROP VIEW  IF EXISTS v_order_value;
DROP VIEW  IF EXISTS v_order_primary_review;
DROP TABLE IF EXISTS order_reviews;
DROP TABLE IF EXISTS order_payments;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS product_categories;
DROP TABLE IF EXISTS geolocation;
DROP TABLE IF EXISTS sellers;
DROP TABLE IF EXISTS customers;


-- ---------------------------------------------------------------------
-- Dimension tables
-- ---------------------------------------------------------------------

-- One row per ZIP prefix. The source file has ~1M rows (many GPS pings
-- per prefix); load_data.py collapses them to one representative point.
CREATE TABLE geolocation (
    zip_code_prefix  TEXT PRIMARY KEY,
    latitude         REAL NOT NULL CHECK (latitude  BETWEEN -34.0 AND  6.0),
    longitude        REAL NOT NULL CHECK (longitude BETWEEN -74.0 AND -34.0),
    city             TEXT NOT NULL,
    state            TEXT NOT NULL CHECK (LENGTH(state) = 2)
);

CREATE TABLE customers (
    customer_id         TEXT PRIMARY KEY,   -- unique per ORDER, not per person
    customer_unique_id  TEXT NOT NULL,      -- the actual person across orders
    zip_code_prefix     TEXT NOT NULL,
    city                TEXT NOT NULL,
    state               TEXT NOT NULL CHECK (LENGTH(state) = 2)
);
CREATE INDEX idx_customers_unique ON customers(customer_unique_id);
CREATE INDEX idx_customers_state  ON customers(state);

CREATE TABLE sellers (
    seller_id        TEXT PRIMARY KEY,
    zip_code_prefix  TEXT NOT NULL,
    city             TEXT NOT NULL,
    state            TEXT NOT NULL CHECK (LENGTH(state) = 2)
);

-- A genuine lookup table: the product categories arrive in Portuguese,
-- and this maps them to English. 71 rows.
CREATE TABLE product_categories (
    category_pt  TEXT PRIMARY KEY,
    category_en  TEXT NOT NULL
);

CREATE TABLE products (
    product_id           TEXT PRIMARY KEY,
    category_pt          TEXT REFERENCES product_categories(category_pt),  -- NULL = uncategorized in source
    name_length          INTEGER,   -- source spells this 'lenght'; corrected here
    description_length   INTEGER,
    photos_qty           INTEGER,
    weight_g             REAL CHECK (weight_g  >= 0),
    length_cm            REAL CHECK (length_cm >= 0),
    height_cm            REAL CHECK (height_cm >= 0),
    width_cm             REAL CHECK (width_cm  >= 0)
);
CREATE INDEX idx_products_category ON products(category_pt);


-- ---------------------------------------------------------------------
-- Fact tables
-- ---------------------------------------------------------------------

CREATE TABLE orders (
    order_id                 TEXT PRIMARY KEY,
    customer_id              TEXT NOT NULL REFERENCES customers(customer_id),
    order_status             TEXT NOT NULL CHECK (order_status IN (
                                 'created','approved','invoiced','processing',
                                 'shipped','delivered','canceled','unavailable')),
    purchased_at             TEXT NOT NULL,   -- ISO-8601
    approved_at              TEXT,            -- NULL until payment clears
    delivered_to_carrier_at  TEXT,            -- NULL until the seller ships
    delivered_to_customer_at TEXT,            -- NULL until it arrives
    estimated_delivery_date  TEXT NOT NULL    -- the promise made at purchase
);
CREATE INDEX idx_orders_status   ON orders(order_status);
CREATE INDEX idx_orders_customer ON orders(customer_id);

-- Grain: one LINE ITEM. order_item_id numbers items within an order,
-- so the primary key is the pair.
CREATE TABLE order_items (
    order_id             TEXT    NOT NULL REFERENCES orders(order_id),
    order_item_id        INTEGER NOT NULL,
    product_id           TEXT    NOT NULL REFERENCES products(product_id),
    seller_id            TEXT    NOT NULL REFERENCES sellers(seller_id),
    shipping_limit_date  TEXT    NOT NULL,   -- seller's contractual handoff deadline
    price                REAL    NOT NULL CHECK (price        >= 0),
    freight_value        REAL    NOT NULL CHECK (freight_value >= 0),
    PRIMARY KEY (order_id, order_item_id)
);
CREATE INDEX idx_items_seller  ON order_items(seller_id);
CREATE INDEX idx_items_product ON order_items(product_id);

-- Grain: one PAYMENT METHOD per order. ~3,000 orders split payment
-- across methods (e.g. a voucher plus a credit card), so summing
-- payment_value without grouping by order double-counts.
CREATE TABLE order_payments (
    order_id             TEXT    NOT NULL REFERENCES orders(order_id),
    payment_sequential   INTEGER NOT NULL,
    payment_type         TEXT    NOT NULL,
    payment_installments INTEGER NOT NULL CHECK (payment_installments >= 0),
    payment_value        REAL    NOT NULL CHECK (payment_value >= 0),
    PRIMARY KEY (order_id, payment_sequential)
);

-- Grain: one review-to-order LINK.
-- review_id is NOT unique: 789 review_ids appear on 2-3 different
-- orders, so the primary key is the pair. See docs/data_cleaning_log.md.
CREATE TABLE order_reviews (
    review_id         TEXT NOT NULL,
    order_id          TEXT NOT NULL REFERENCES orders(order_id),
    review_score      INTEGER NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    comment_title     TEXT,
    comment_message   TEXT,
    created_at        TEXT NOT NULL,
    answered_at       TEXT,
    PRIMARY KEY (review_id, order_id)
);
CREATE INDEX idx_reviews_order ON order_reviews(order_id);
