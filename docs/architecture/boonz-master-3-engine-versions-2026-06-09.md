# boonz-master-3 — engine-version refresh (2026-06-09, Refill v2)

The installed `boonz-master-3` skill is a read-only plugin (can't be edited from a Cowork session).
Update it via **Settings → Capabilities**. Replace the stale "Current engine versions" table and the
cron description with the block below. Everything else in the skill (Hard Rules, gates, Path A/B/C,
checklists) stays as-is.

## Current engine versions (live 2026-06-09 — Refill v2)

| Stage            | RPC                          | Version | Notes                                                                                                                                                                                                                                                                                                                            |
| ---------------- | ---------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cron — Draft gen | `build_draft_for_confirmed`  | live    | 8pm Dubai (cron 13, `0 16 * * *`, prefixed `SET statement_timeout='1200000'`). Auto-confirms the pick, then chains `engine_add_pod` → `engine_swap_pod` → `engine_finalize_pod`, STOPS at the draft. Replaces `auto_generate_draft`.                                                                                             |
| Cron — Picker    | `pick_machines_for_refill`   | v8      | 6am Dubai (cron 14, `0 2 * * *`).                                                                                                                                                                                                                                                                                                |
| 0 — Gate         | `_assert_gate_zero`          | —       | refuses Stage 2 if picked rows lack `confirmed_at`.                                                                                                                                                                                                                                                                              |
| 0 — Confirm      | `confirm_machines_to_visit`  | live    | auto-called by `build_draft_for_confirmed` (CS approved auto-confirm for DRAFT gen, 2026-06-07).                                                                                                                                                                                                                                 |
| 1 — Picker       | `pick_machines_for_refill`   | **v8**  | P1 bands mirror `get_machine_health.priority_tier` (empty / runway<3 / strong-seller-low); warehouses+excluded dropped; venue-sibling expansion kept.                                                                                                                                                                            |
| 2a — Engine ADD  | `engine_add_pod`             | **v15** | FILL-TO-CAPACITY: every selling shelf fills to `max_stock − current`; WH scarcity is the only throttle (best shelves first). Dead = no sales (v7=0 AND v30=0) → qty 0 + swap tag in `pod_swaps`. Quantity decoupled from score; `compute_refill_decision`/Pearson are RANKING only. Lifecycle stance does NOT gate refill.       |
| 2b — Engine SWAP | `engine_swap_pod`            | **v10** | Narrow trigger: only the add-tagged dead/rotate shelves + driver `wrong_product`. Swap-in via `find_substitutes_for_shelf` (global-performer-first), qty_in = fill-to-cap capped by WH, no duplicate swap-in per machine/run. M2W downstream. Autonomous-Pearson + lifecycle passes REMOVED. Pass-1 strategic-intent swaps kept. |
| 2.5 — Reco       | `find_substitutes_for_shelf` | v2      | global performers NOT in the machine, in real `warehouse_stock`, ranked by correlation to the machine's basket. (Not anchored on the removed product anymore.)                                                                                                                                                                   |
| 2.5 — Driver     | `resolve_driver_intent`      | NEW     | read-only translator: driver_feedback + driver_recommendations → {pod, boonz, qty, shelf A01-A16}; unresolved flagged, never dropped.                                                                                                                                                                                            |
| 2c — Finalize    | `engine_finalize_pod`        | v9      | unchanged; consolidates to `pod_refill_plan`, carries `decision`.                                                                                                                                                                                                                                                                |
| 2.5 — Source tag | `mark_internal_transfer`     | live    | canonical writer for `source_origin='internal_transfer'`.                                                                                                                                                                                                                                                                        |
| 3 — Stitch       | `stitch_pod_to_boonz`        | **v19** | product_mapping % split + driver SKU overlay (first-claim, remainder by mix_weight; no-op until driver data) + defensive shelf-code canonical guard.                                                                                                                                                                             |
| 4 — Bridge       | `push_plan_to_dispatch`      | v3      | unchanged.                                                                                                                                                                                                                                                                                                                       |

## What changed vs the old table (so the conductor doesn't reference dead versions)

- picker v4 → **v8**; engine_add v8 → **v15**; engine_swap v8 → **v10**; stitch v11.1 → **v19**.
- `auto_generate_draft` is retired in the cron; the nightly path is `build_draft_for_confirmed`
  (auto-confirm + add + swap + finalize, stops at draft).
- New canonical/read RPCs: `resolve_driver_intent`, `confirm_machines_to_visit`; `find_substitutes_for_shelf`
  rewritten to global-performer-first.
- Core principle to enforce in any "why is qty X" diagnostic: **fill quantity = fill-to-capacity for
  sellers, 0 for genuine no-sellers (tagged for swap); score never caps fill.**

See [[project_refill_v2_deployed_2026-06-08]] memory + `docs/prds/refill-pipeline/PRD-REFILL-V2-add-swap-rebuild.md`.
