"""
run_analysis.py

Runs every named query in sql/03_analysis.sql, prints the result, and
writes it to output/<query_name>.csv. Those CSVs are what the dashboard
reads from.

Run from the project root, after load_data.py:
    python src/run_analysis.py
"""

import re
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DB_FILE = ROOT / "data" / "olist.db"
QUERY_FILE = ROOT / "sql" / "03_analysis.sql"
OUT_DIR = ROOT / "output"

# Queries that return one row per seller/category/state: save the full
# result, but print only the head and tail so the console stays readable.
PREVIEW_ONLY = {"seller_scorecard": 10, "category_performance": 10}


def parse_named_queries(sql_text: str) -> dict[str, str]:
    """Splits the file on '-- name: <query_name>' lines."""
    parts = re.split(r"^--\s*name:\s*(\w+)\s*$", sql_text, flags=re.MULTILINE)
    # parts = [header, name1, body1, name2, body2, ...]
    return {parts[i]: parts[i + 1].strip() for i in range(1, len(parts), 2)}


def show(name: str, df: pd.DataFrame) -> None:
    print(f"\n=== {name} ({len(df):,} rows) ===")
    limit = PREVIEW_ONLY.get(name)
    if limit and len(df) > 2 * limit:
        print(df.head(limit).to_string(index=False))
        print(f"   ... {len(df) - 2 * limit:,} more rows ...")
        print(df.tail(limit).to_string(index=False))
    else:
        print(df.to_string(index=False))


def main() -> None:
    if not DB_FILE.exists():
        raise SystemExit("Database not found. Run `python src/load_data.py` first.")

    OUT_DIR.mkdir(exist_ok=True)
    queries = parse_named_queries(QUERY_FILE.read_text())

    with sqlite3.connect(DB_FILE) as con:
        for name, sql in queries.items():
            result = pd.read_sql_query(sql, con)
            result.to_csv(OUT_DIR / f"{name}.csv", index=False)
            show(name, result)

    print(f"\nSaved {len(queries)} result files to {OUT_DIR.relative_to(ROOT)}/")


if __name__ == "__main__":
    pd.set_option("display.width", 200)
    main()
