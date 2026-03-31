# VOX Cinema Analytics for Boonz

## Data Model

Two data sources joined at the transaction level:

- POS machine export: what the machine sold (quantity, product, total amount)
- Adyen payment export: what was actually captured (payment status, wallet type)

Join key: Adyen "Merchant Reference" = POS "Internal Transaction S/N"
Strip the \_N suffix from the POS S/N to get txn_base for matching.

## Sites

- Mercato: store key VOXMM, 2 machines (Machine 1 = VOX, Machine 2 = Boonz)
- Mirdif City Centre: store key VOXMCC
- Exclude pre-Feb 6 transactions (test period)

## Key Metrics

- Default rate: (Total amount - Captured Amount) / Total amount × 100
- Total amount is the correct sales baseline (NOT Paid amount)
- Current rates: overall 2.23%, Mercato 4.2%, Mirdif 1.1%

## Dashboard Structure (6 tabs)

1. Overview — KPIs, revenue trend, daily avg transactions
2. Sites & Machines — site comparison, per-machine breakdown
3. Products — volume vs value bubble chart, top products
4. Eid Analysis — holiday period performance
5. Payments — wallet types, payment methods
6. Transactions — ONLY tab showing both Total Sales AND Captured Amount side by side

All tabs except Transactions use Total amount exclusively.

## Supabase Migration Plan (NOT YET EXECUTED)

13 tables: 2 raw staging + 11 analytics
ETL pipeline: Python (run_etl.py) → Supabase tables → TypeScript lib (vox-data.ts) → API route (/api/vox/dashboard) → Page (/app/vox)
Existing state: adyen_transactions has 9,930 rows, needs token_payment_variant column added.
