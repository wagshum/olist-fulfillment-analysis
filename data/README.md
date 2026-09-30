# data/

This folder holds the raw source files and the generated database. Both are
excluded from git (see `.gitignore`) because the raw CSVs total roughly 126 MB
and the geolocation file alone exceeds GitHub's file-size warning threshold.

## Rebuilding the database

1. Download the **Brazilian E-Commerce Public Dataset by Olist** from Kaggle:
   https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

2. Place these nine files in `data/raw/`:

   ```
   olist_customers_dataset.csv
   olist_geolocation_dataset.csv
   olist_order_items_dataset.csv
   olist_order_payments_dataset.csv
   olist_order_reviews_dataset.csv
   olist_orders_dataset.csv
   olist_products_dataset.csv
   olist_sellers_dataset.csv
   product_category_name_translation.csv
   ```

3. From the project root:

   ```bash
   python src/load_data.py      # writes data/olist.db and verifies the load
   python src/run_analysis.py   # writes output/*.csv
   ```

The loader checks row counts, foreign keys, and payment totals against the
source on every run, so a failed assertion means the input changed rather than
the analysis silently shifting.
