# Olist Fulfillment Pipeline and Delivery Promise Analysis

Where does a Brazilian e-commerce marketplace lose time between checkout and the customer's door, and what does a missed delivery promise actually cost?

This project analyzes 99,441 orders from Olist, a Brazilian marketplace, across nine related tables. It measures how long each stage of fulfillment takes, isolates which stage drives late deliveries, quantifies the satisfaction cost of breaking a delivery promise, and identifies where intervention would pay off most.

> **About the data:** Real transaction data published by Olist, covering September 2016 to October 2018. Findings describe that marketplace in that period. Source: [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) (Kaggle)

## Key findings

**Breaking a delivery promise is catastrophic for satisfaction.** Olist gives every customer an estimated delivery date at checkout. Missing it collapses the review score:

| Delivery outcome | Orders | Avg review | 1-star rate |
|---|---|---|---|
| Early | 88,149 | 4.29 | 6.6% |
| On the promised day | 1,280 | 4.04 | 8.4% |
| 1–3 days late | 1,852 | 3.29 | 25.2% |
| 4–7 days late | 1,747 | 2.10 | 58.5% |
| 8–14 days late | 1,446 | 1.67 | 70.6% |
| 15+ days late | 1,335 | 1.73 | 68.8% |

The damage is not gradual. Between "on time" and "4–7 days late" the 1-star rate rises sevenfold, and most of the penalty lands within the first week.

**Transit dominates the timeline, and it is where late orders go wrong.**

| Stage | Median | 90th percentile | On-time orders | Late orders |
|---|---|---|---|---|
| Payment approval | 0.3 hrs | 33.3 hrs | 0.3 hrs | 0.4 hrs |
| Seller handoff | 44.4 hrs | 144.5 hrs | 43.0 hrs | 73.6 hrs |
| Carrier transit | 170.6 hrs | 454.7 hrs | 167.0 hrs | 628.8 hrs |

Transit is 79% of total fulfillment time, and late orders spend an extra 462 hours there. Seller handoff adds another 31 hours when orders run late — a smaller effect, but the one the marketplace can directly influence.

**Late deliveries concentrate in a minority of sellers.** Among 425 sellers with 50+ delivered orders, late rates range from 0% to 32%. The worst 30% of sellers account for **52% of all late orders**, which makes seller-level intervention more valuable than a uniform process change.

**On-time performance collapses under seasonal load.** Late rates sit near 3% in stable months but spike to 12.4% in November 2017 (Black Friday) and 19.0% in March 2018 — a capacity problem, not a steady-state one.

**Geography sets a floor on what is achievable.** Maranhão runs 17.8% late with a median transit of 15.7 days; Paraná runs 4.1% late at 7.2 days. Any national delivery promise has to account for this spread.

**Padding the promise is not a free fix.** Orders promised 30+ days out are late only 5.0% of the time versus 10.5% for promises under 10 days — but their average review score is *lower* (4.07 vs 4.34). Customers notice a long promise even when it is kept.

**Revenue exposure:** late orders carry $985,745 in merchandise value, and 60.9% of them receive a 1- or 2-star review, versus 9.2% of on-time orders.

## Recommendations

1. **Target the worst-performing sellers first.** 129 sellers drive over half of all late orders. Handoff-time SLAs and scorecards for that group address the largest share of the problem with the narrowest intervention.
2. **Build seasonal capacity plans.** The Black Friday and March spikes are predictable and should be reflected in carrier capacity and promise dates.
3. **Set delivery promises regionally rather than nationally.** A single national buffer either over-promises in the North or under-promises in the Southeast, and over-long promises carry their own satisfaction cost.

These are observational findings. Late delivery is strongly associated with poor reviews, but other factors (product category, seller quality, order value) may contribute to both.

## Project structure

```
olist-fulfillment/
├── data/raw/                 nine source CSVs (not committed)
├── sql/
│   ├── 01_schema.sql         nine tables, foreign keys, CHECK constraints
│   ├── 02_views.sql          fulfillment view, stage unpivot, seller scorecard
│   └── 03_analysis.sql       ten named analysis queries
├── src/
│   ├── load_data.py          clean, load, and verify
│   └── run_analysis.py       run queries, write output/*.csv
├── output/                   query results as CSV (feeds the dashboard)
└── docs/
    └── data_cleaning_log.md  every cleaning decision and its evidence
```

## Schema

Nine tables at three different grains. Getting the grain right is the core of the analysis: `order_items` is per line item, `order_payments` is per payment method, and `orders` is per order, so totals must be aggregated before joining or they inflate.

```
product_categories ──< products ──┐
                                   ├──< order_items >── sellers
geolocation                        │
customers ──< orders ──────────────┤
                                   ├──< order_payments
                                   └──< order_reviews
```

## How to run

```bash
pip install -r requirements.txt
# place the nine Olist CSVs in data/raw/ (see data/README.md)
python src/load_data.py      # builds data/olist.db, verifies the load
python src/run_analysis.py   # prints results, writes output/*.csv
```

## Techniques used

- Nine-table relational schema with foreign keys and `CHECK` constraints
- Window functions (`ROW_NUMBER`, `NTILE`) for medians, percentiles, deduplication, and concentration analysis
- CTEs for multi-step aggregation
- Wide-to-long unpivoting so all pipeline stages share one query
- Grain-aware aggregation to prevent join fan-out, verified against source totals
- Automated verification: row counts, foreign key checks, and total reconciliation on every load

## Status

- [x] Schema design and verified data load
- [x] Data cleaning with documented decisions
- [x] Pipeline, promise, seller, category, geography, and trend analysis
- [ ] Dashboard (Tableau / Power BI)
- [ ] One-page executive memo
