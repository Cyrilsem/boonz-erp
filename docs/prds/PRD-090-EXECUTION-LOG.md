# PRD-090 Execution Log — Niche merchandising fill (SHIP DARK)

Run 2026-07-08 overnight (WAVE1-OVERNIGHT), AUTO. **Status: SHIPPED DARK (add_niche_fill_v1=off).**
Cody PASS. Other-3 Family A md5 `11b0b03f` UNCHANGED. **NOT ENABLED (CS-only).**

## Shipped (behind add_niche_fill_v1, seeded OFF)
- `refill_policy_params += niche_footprint_max (2), niche_facing_target (0.8)`.
- `engine_add_pod`: flag-gated niche term appended to need_raw's GREATEST — footprint
  (distinct active machines carrying the pod_product, via `slot_lifecycle`) ≤ max AND this
  shelf is best location (max v30) ⇒ floor to `CEIL(target×cap)`. Adds 0 when off (inert).
  Downstream fill_to_cap + pickable wh_avail clamp UNCHANGED (T3: quarantined never promised).

## Bug found + forward-fixed (fixture could not catch it)
The first migration's footprint subquery used `pod_inventory.pod_product_id` — which does NOT
exist (`pod_inventory` keys on `boonz_product_id`). It shipped dark-inert (Postgres prunes the
unreachable subquery when the flag is off) but would have CRASHED on enable. Forward-fix
`prd090_fix_footprint_source_slot_lifecycle` switches to `slot_lifecycle` (the pod_product_id
placement source). Standalone-validated: **19 niche pod_products** (footprint ≤ 2) of 69 placed.

## Ship gate (met)
- flag OFF ⇒ `diff_vs_golden` IDENTICAL (proven post-fix). Other-3 Family A `11b0b03f` unchanged.

## ON-delta report for CS — FIXTURE LIMITATION (read this)
- **The golden_v1 fixture (2026-07-06) is 100% manual/non-engine-sized rows.** Fleet-wide, NO
  recent plan_date (last 30d) contains engine ADD-sized rows (`engine_add_pod` covered/flagged
  path is dormant in current operations / base_stock mode). So **flag-ON delta = 0 on every
  available capture** — the behavioural effect cannot be previewed against real captured plans.
- **What IS validated:** inertness (flag off), column-correctness (all refs schema-checked;
  footprint executes standalone), and the impact SET: **19 pod_products** would qualify for the
  facing floor at their best location when enabled (subject to pickable wh_avail).
- **CS action:** review a real engine-sized ADD plan delta before enabling. See the program-park
  in MASTER-PARKING-LOT (Wave-1 ON-validation needs an engine-ADD fixture).

## Status: SHIPPED DARK. Enable = CS sets add_niche_fill_v1=on after a real engine-sized delta review.
