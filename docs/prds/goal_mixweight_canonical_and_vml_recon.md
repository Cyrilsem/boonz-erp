# /goal — mix_weight canonical + VML 2026-06-03 reconciliation

Repo: `boonz-erp/`. Supabase: `eizcexopcuoycuosittm`. Read `01_constitution.html`, `RPC_REGISTRY.md`, `MIGRATIONS_REGISTRY.md` in `docs/architecture/`.

**Governance:** no `boonz-master-3` here. Use `dara` (data), `cody` (review every SECURITY DEFINER fn + protected DDL), `stax` (FE).

**Hard rules:** (1) Cody-review every fn/DDL on a protected entity. (2) No raw writes on protected tables (product_mapping, refill_plan_output, refill_dispatching, warehouse_inventory, pod_inventory) — canonical RPC only. (3) No inventory move without per-row diff + CS sign-off; archive never DELETE. (4) Apply nothing to prod without CS sign-off — stage migrations, STOP at each apply and each WS-B diff. (5) Even splits ±1, FEFO oldest first. No em-dashes.

## WS-A — make mix_weight canonical (code)

`apply_mix_weight_recommendation` writes `product_mapping.mix_weight`, but the pod→SKU fan-out reads `split_pct`, so confirmed recommendations are inert. `mix_weight` is 0–1.0 (sum 1.0/pod); `split_pct` is 0–100; both populated on all 7,662 active rows. Column-switch + scale change in each formula: `pod_qty*split_pct/100` → `pod_qty*mix_weight`; `split_pct>0` → `mix_weight>0`; `total_split=0` fallback → `1.0/variant_n`.

Step 0 (read-only, show CS first): report rows where `mix_weight` diverges from `split_pct/100` (tol 0.005), grouped by machine+pod. Divergence = approved recommendation (intended live) or drift; CS decides which to snap back (canonical writer, not raw UPDATE).

Step 1 (Dara design → Cody review each → stage): switch these 6 split_pct readers to mix_weight, diff-gated (only split source + scale change):

- `stitch_pod_to_boonz` v17→v18 — PRIMARY, the fan-out. Preserve the inline confirm gate (`skipped_write_failed`), the WS6.2 0-stock filter, the WS1b physical-fallback path; re-verify all present after apply.
- `get_procurement_demand` — PRIMARY, must match stitch.
- `reconcile_pod_inventory_shelf`, `backfill_dispatch_boonz_product_ids`, `assert_product_launch_ready` — secondary.
- `apply_mix_weight_recommendation` — writer, leave as-is.

Step 2: keep split_pct as read-only mirror 30 days (drop 2026-07-04), don't drop now.

Accept: confirmed 20/40/40 recommendation makes stitch dry-run emit 20/40/40; stitch and procurement agree; untouched pod v18 == v17 (prove on 3 machines); update the 3 registries.

## WS-B — VML-1003 2026-06-03 reconciliation (data)

GOTCHA: `receive_dispatch_line` only debits WH when a consumer reservation exists. These packed lines have NONE (WH still holds all stock), so a bare receive inflates (units in WH AND pod). Correct: reserve (WH→consumer, verify `pack_dispatch_line` on packed rows) THEN receive (consumer→pod). STOP, show CS diff per line.

10 lines (date 2026-06-03, VML-1003-0400-O1, packed, not picked):
44d681dc A01 Popit Orange 1·62e53f94 A01 Popit Lime 1·d21c99c0 A07 McVities ChocoCaramel 1·9398b499 A15 Popit Lime 5·b0a5c936 A15 Popit Cola 5·9143be23 A15 Popit Orange 4·63701c13 A16 Popcorn Butter 2·dfabedff A16 Popcorn Salted 1 — all pinned.
c09ed44c A01 Coke Zero 14·2f34c3ab A03 Coke Zero 14 — UNPINNED, need FEFO pick.

Coke Zero 28u FEFO from WH_CENTRAL (4bebef68): 42245d17 Oct4 ×6, 6b6a369a Oct18 ×6, 9d733755 Oct26 ×2, 449f8625 Nov3 ×14. Re-verify live first.

2 transfers (confirm amount w/ CS, canonical transfer RPC): Mindshare Vitamin Well Upgrade 24 in WH_MCC→CENTRAL; WPP Perrier 12.

Accept: each line picked_up+item_added, WH batch debited by filled qty, pod credited, net physical units = 0, no double-count; transfers land in right WH; log it.

## Order

1. WS-A Step0 report→CS. 2) WS-A stitch+procurement first, then 3 secondaries (stage, STOP to apply). 3) WS-A Step2. 4) WS-B: 8 pinned, then 2 FEFO Coke Zero, then 2 transfers — STOP per diff.
   Do safe/staging work uninterrupted; STOP only at the gates. Log unfinished work.
