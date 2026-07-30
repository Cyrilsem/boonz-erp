# /goal — PRD-106 + PRD-107 combined production push (swap engine + pack stage)

GOAL: Ship TWO fixes to production in one session, in order: (A) PRD-107 pack-stage truth (smaller, unblocks daily ops) then (B) PRD-106 machine-level swap recommender. Read PRD-107-pack-stage-remove-legs-and-progress-truth.md and PRD-106-swap-machine-level-recommendation.md FIRST. Supabase eizcexopcuoycuosittm. Dara designs schema/view changes, Stax implements FE + push wiring, Cody constitutional review MANDATORY before EACH migration applies. Write EXECUTION-LOGs (PRD-107-EXECUTION-LOG.md, PRD-106-EXECUTION-LOG.md).

WHY: Two recurring production failures, both proven 2026-07-29. (1) PACK: warehouse packs everything packable but machines strand at "Mark All Packed" — "packable" is defined differently in 3 places: FE counts Remove legs, confirm_machine_packed excludes them (action IN ('Refill','Add New','Add')), pack_dispatch_line resolves them only per-tap ('packed_no_pick'). Every swap creates Remove legs → every swap plan strands the board. Also 10 rows packed=true with pack_outcome NULL (no constraint), and MC A15's REMOVE nearly emptied a shelf after its paired ADD_NEW went not_filled. (2) SWAP: old engine_swap_pod recommended Barebells onto MC-2004 (already on B09) and Coca Cola Zero onto MC A06 + HUAWEI A12 (already live facings); find_substitutes_for_shelf returns the IDENTICAL list for every shelf on a machine; RC-06 severed dead-tag matching since 06-22.

PART A — PRD-107 (pack stage):
A1. View v_dispatch_pack_progress(machine_id, dispatch_date): total_included, packable_n (Refill/Add New/Add), resolved_n (packed|partial|not_filled|skipped|no_pack_needed), driver_action_n (Remove/M2W/M2M-source), orphaned_swap_legs jsonb, ready_to_pack_close bool. SINGLE source of truth — confirm_machine_packed AND the FE board both read it; kill the FE's own denominator.
A2. pack_outcome enum + 'no_pack_needed'; push_plan_to_dispatch stamps it on driver-side legs at push. Backfill historical packed=true/outcome-NULL rows, then constraint: packed=true ⇒ pack_outcome NOT NULL.
A3. Orphan guard in confirm_machine_packed(final): shelf with REMOVE whose paired ADD_NEW ended not_filled/skipped → needs_review='orphaned_swap_leg', returned in response with proposed skip; never silent.
A4. Driver manifest depends ONLY on include/cancelled/skipped, never packed/pack_outcome (Stax audit).
A5. FE: progress = resolved/packable, Removes shown as "+N driver actions", button gated by ready_to_pack_close, orphan banner with one-tap skip. FE must not read dispatch_pack_confirmation for state either — the view is the state.

PART B — PRD-106 (swap engine):
B1. RPC recommend_swaps_for_machine(p_plan_date, p_machine_id, p_k DEFAULT dead-shelf count) → K rows (shelf_id, shelf_code, out/in pod ids+names, qty_suggested, rank_score, wh_available, rationale jsonb).
B2. Universe: Active pods with Active mapping MINUS in-machine products per latest WEIMI (zero-pad A1→A01; EXCEPTION: existing facing has engine_add_pod stance='DOUBLE DOWN'), decommission-intent products, slot-profile-incompatible (PRD-042), Evian 1L, venue_team products on non-VOX machines.
B3. wh_available: aggregate v_wh_pickable by boonz_product_id BEFORE mapping to pod grain (product_mapping join fan-out inflates ~10x: Red Bull 1599 vs real 39). Respect machine warehouse routing.
B4. rank_score = basket_corr × ln(1+fleet_units_30d) × availability_factor (0 below merchandising floor; FEFO-pressure boost). Components in rationale.
B5. Greedy-assign top DISTINCT candidates to shelves ranked by capacity×placement_mult; no product repeated across K rows; qty = min(max_stock, wh_available).
B6. Rewire engine_swap_pod to consume it per machine; find_substitutes_for_shelf gains p_exclude_in_machine DEFAULT true for FE. Fix RC-06: dead-tag match via source LIKE 'engine_add_pod%'.
B7. M2W BANNED as auto-outcome: no viable candidate → qty-0 row reason='no_viable_swap_candidate' + procurement alert. Never auto-suppress.

GUARDRAILS: read-only until Cody approves each migration; no raw DML on pod_refill_plan/refill_dispatching (RPCs only); protect_packed_dispatch_row untouched; no engine version downgrades; enum + backfill + constraint in one migration, constraint enabled only after zero violations; test on branch/dry-run harness; Title Case dispatching actions; no em-dashes in client copy.

ACCEPTANCE (gate production push on ALL):

- 07-29 MC-2004 replay: view shows packable 32=resolved, 7 driver actions, ready_to_pack_close true; A15 REMOVE flagged orphaned_swap_leg; FE and RPC cannot disagree (pgTAP parity).
- Zero packed=true/outcome-NULL rows fleet-wide; constraint blocks new ones; driver app shows Remove legs on pack-closed machines.
- Swap replay MC-2004 (A11/B02/B03): 3 DISTINCT ins, none already on machine, no Coca Cola Mix/Barebells-class dup, wh_available ≥ qty (deduped); Hunter replay: no within-machine dup; RC-06 gone (v18/v19 tags resolve); full-fleet stitch dry-run: zero blocked_no_wh on swap rows.
- pgTAP: fan-out dedup, DOUBLE DOWN exception, distinct-K, decommission exclusion, orphan-pair detection, no_pack_needed stamping.
- Cody verdicts recorded in both EXECUTION-LOGs before apply; Vercel FE deploy last, after backend green.
