"""
load_data.py

Reads the nine raw Olist CSVs, cleans them, and loads them into a SQLite
database. Every cleaning decision is explained in docs/data_cleaning_log.md.

Run from the project root:
    python src/load_data.py
"""

import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
DB_FILE = ROOT / "data" / "olist.db"
SQL_DIR = ROOT / "sql"

# Brazil's mainland bounding box, used to drop clearly corrupt GPS points.
BRAZIL_BBOX = {"lat_min": -34.0, "lat_max": 6.0, "lng_min": -74.0, "lng_max": -34.0}


def read(name: str, **kwargs) -> pd.DataFrame:
    df = pd.read_csv(RAW / f"{name}.csv", **kwargs)
    print(f"  read {name}: {len(df):,} rows")
    return df


# ---------------------------------------------------------------------
# Per-table cleaning
# ---------------------------------------------------------------------

def clean_geolocation() -> pd.DataFrame:
    """~1M GPS pings collapse to one representative point per ZIP prefix."""
    g = read("olist_geolocation_dataset")

    outside = (
        (g.geolocation_lat < BRAZIL_BBOX["lat_min"]) | (g.geolocation_lat > BRAZIL_BBOX["lat_max"]) |
        (g.geolocation_lng < BRAZIL_BBOX["lng_min"]) | (g.geolocation_lng > BRAZIL_BBOX["lng_max"])
    )
    print(f"  dropped {outside.sum()} GPS points outside Brazil")
    g = g[~outside]

    g["geolocation_zip_code_prefix"] = g.geolocation_zip_code_prefix.astype(str).str.zfill(5)

    # Median coordinates, not mean: a single mistyped point would drag a
    # mean across the country, while the median ignores it.
    coords = g.groupby("geolocation_zip_code_prefix")[["geolocation_lat", "geolocation_lng"]].median()

    # City names vary in spelling and accents within a prefix, so take the
    # most frequent spelling rather than an arbitrary one.
    labels = (g.groupby("geolocation_zip_code_prefix")[["geolocation_city", "geolocation_state"]]
                .agg(lambda s: s.mode().iat[0]))

    out = coords.join(labels).reset_index()
    out.columns = ["zip_code_prefix", "latitude", "longitude", "city", "state"]
    print(f"  geolocation: {len(g):,} pings -> {len(out):,} ZIP prefixes")
    return out


def clean_customers() -> pd.DataFrame:
    c = read("olist_customers_dataset", dtype={"customer_zip_code_prefix": str})
    c.columns = ["customer_id", "customer_unique_id", "zip_code_prefix", "city", "state"]
    c["zip_code_prefix"] = c.zip_code_prefix.str.zfill(5)
    assert c.customer_id.is_unique, "customer_id is not unique"
    return c


def clean_sellers() -> pd.DataFrame:
    s = read("olist_sellers_dataset", dtype={"seller_zip_code_prefix": str})
    s.columns = ["seller_id", "zip_code_prefix", "city", "state"]
    s["zip_code_prefix"] = s.zip_code_prefix.str.zfill(5)
    assert s.seller_id.is_unique, "seller_id is not unique"
    return s


def clean_categories(products: pd.DataFrame) -> pd.DataFrame:
    # encoding='utf-8-sig' strips the byte-order mark this file starts with.
    # Without it the first column name reads '﻿product_category_name'
    # and every join on it silently fails.
    t = read("product_category_name_translation", encoding="utf-8-sig")
    t.columns = ["category_pt", "category_en"]

    # A few categories appear on products but are absent from the
    # translation file. Rather than drop those products, add the missing
    # categories with a readable English fallback built from the
    # Portuguese name, and say so.
    used = set(products.category_pt.dropna())
    missing = sorted(used - set(t.category_pt))
    if missing:
        print(f"  {len(missing)} categories missing from translation file: {missing}")
        fallback = pd.DataFrame({
            "category_pt": missing,
            "category_en": [m.replace("_", " ") + " (untranslated)" for m in missing],
        })
        t = pd.concat([t, fallback], ignore_index=True)
    return t


def clean_products() -> pd.DataFrame:
    p = read("olist_products_dataset")
    # The source misspells 'length' as 'lenght' in two column names.
    p.columns = ["product_id", "category_pt", "name_length", "description_length",
                 "photos_qty", "weight_g", "length_cm", "height_cm", "width_cm"]
    assert p.product_id.is_unique, "product_id is not unique"
    print(f"  products with no category: {p.category_pt.isna().sum():,}")
    return p


def clean_orders() -> pd.DataFrame:
    ts_cols = ["order_purchase_timestamp", "order_approved_at",
               "order_delivered_carrier_date", "order_delivered_customer_date",
               "order_estimated_delivery_date"]
    o = read("olist_orders_dataset", parse_dates=ts_cols)
    o.columns = ["order_id", "customer_id", "order_status", "purchased_at",
                 "approved_at", "delivered_to_carrier_at",
                 "delivered_to_customer_at", "estimated_delivery_date"]
    assert o.order_id.is_unique, "order_id is not unique"

    # SQLite has no datetime type; its date functions read ISO-8601 text.
    for col in ["purchased_at", "approved_at", "delivered_to_carrier_at",
                "delivered_to_customer_at", "estimated_delivery_date"]:
        o[col] = o[col].dt.strftime("%Y-%m-%d %H:%M:%S")

    for col in ["approved_at", "delivered_to_carrier_at", "delivered_to_customer_at"]:
        print(f"  {col}: {o[col].isna().sum():,} NULL")
    return o


def clean_order_items() -> pd.DataFrame:
    i = read("olist_order_items_dataset", parse_dates=["shipping_limit_date"])
    i.columns = ["order_id", "order_item_id", "product_id", "seller_id",
                 "shipping_limit_date", "price", "freight_value"]
    i["shipping_limit_date"] = i.shipping_limit_date.dt.strftime("%Y-%m-%d %H:%M:%S")
    assert not i.duplicated(["order_id", "order_item_id"]).any(), \
        "(order_id, order_item_id) is not unique"
    return i


def clean_payments() -> pd.DataFrame:
    p = read("olist_order_payments_dataset")
    p.columns = ["order_id", "payment_sequential", "payment_type",
                 "payment_installments", "payment_value"]
    assert not p.duplicated(["order_id", "payment_sequential"]).any(), \
        "(order_id, payment_sequential) is not unique"
    n_split = (p.groupby("order_id").size() > 1).sum()
    print(f"  orders paid with more than one method: {n_split:,}")
    return p


def clean_reviews() -> pd.DataFrame:
    r = read("olist_order_reviews_dataset",
             parse_dates=["review_creation_date", "review_answer_timestamp"])
    r.columns = ["review_id", "order_id", "review_score", "comment_title",
                 "comment_message", "created_at", "answered_at"]

    # review_id is NOT unique: some IDs appear on several different orders.
    # The unique key is the (review_id, order_id) pair.
    n_dup_ids = r.review_id.duplicated().sum()
    print(f"  review_id values reused across orders: {n_dup_ids:,}")
    assert not r.duplicated(["review_id", "order_id"]).any(), \
        "(review_id, order_id) is not unique either"

    n_multi = (r.groupby("order_id").size() > 1).sum()
    print(f"  orders with more than one review: {n_multi:,}")

    for col in ["created_at", "answered_at"]:
        r[col] = r[col].dt.strftime("%Y-%m-%d %H:%M:%S")
    return r


# ---------------------------------------------------------------------
# Load and verify
# ---------------------------------------------------------------------

def load(frames: dict[str, pd.DataFrame]) -> None:
    DB_FILE.unlink(missing_ok=True)
    con = sqlite3.connect(DB_FILE)
    con.execute("PRAGMA foreign_keys = ON")
    con.executescript((SQL_DIR / "01_schema.sql").read_text())

    # Parents before children, so every foreign key resolves on insert.
    order = ["geolocation", "customers", "sellers", "product_categories",
             "products", "orders", "order_items", "order_payments", "order_reviews"]
    for table in order:
        df = frames[table]
        df.astype(object).where(df.notna(), None).to_sql(
            table, con, if_exists="append", index=False, chunksize=10_000, method="multi"
        )
        print(f"  loaded {len(df):,} rows into {table}")

    con.executescript((SQL_DIR / "02_views.sql").read_text())
    con.commit()
    verify(con, frames)
    con.close()


def verify(con: sqlite3.Connection, frames: dict[str, pd.DataFrame]) -> None:
    for table, df in frames.items():
        got = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        assert got == len(df), f"{table}: expected {len(df):,} rows, loaded {got:,}"

    violations = con.execute("PRAGMA foreign_key_check").fetchall()
    assert not violations, f"Foreign key violations: {violations[:5]}"

    # One review per order in the primary-review view.
    dupes = con.execute(
        "SELECT COUNT(*) FROM (SELECT order_id FROM v_order_primary_review "
        "GROUP BY order_id HAVING COUNT(*) > 1)"
    ).fetchone()[0]
    assert dupes == 0, f"{dupes} orders have more than one primary review"

    # v_order_value must not inflate money by fanning out items x payments.
    sql_total = con.execute("SELECT ROUND(SUM(payment_total), 2) FROM v_order_value").fetchone()[0]
    raw_total = round(frames["order_payments"].payment_value.sum(), 2)
    assert abs(sql_total - raw_total) < 1, \
        f"Payment total changed during load: {sql_total:,.2f} vs {raw_total:,.2f}"

    n_fulfilled = con.execute("SELECT COUNT(*) FROM v_order_fulfillment").fetchone()[0]
    n_anomaly = con.execute(
        "SELECT COUNT(*) FROM v_order_fulfillment WHERE has_timestamp_anomaly = 1"
    ).fetchone()[0]
    print(f"\n  Verified: 9 tables, no FK violations, payment totals match")
    print(f"  Analysis set: {n_fulfilled:,} delivered orders with complete timestamps")
    print(f"  Of those, {n_anomaly:,} have out-of-order timestamps "
          f"({n_anomaly / n_fulfilled * 100:.1f}%) and are excluded from stage-duration queries")


if __name__ == "__main__":
    print("Reading and cleaning:")
    products = clean_products()
    frames = {
        "geolocation":        clean_geolocation(),
        "customers":          clean_customers(),
        "sellers":            clean_sellers(),
        "product_categories": clean_categories(products),
        "products":           products,
        "orders":             clean_orders(),
        "order_items":        clean_order_items(),
        "order_payments":     clean_payments(),
        "order_reviews":      clean_reviews(),
    }
    print("\nLoading:")
    load(frames)
    print(f"\nDatabase written to {DB_FILE.relative_to(ROOT)}")
