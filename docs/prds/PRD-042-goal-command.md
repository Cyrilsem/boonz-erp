# Claude Code /goal — PRD-042 swap slot-profile pools (engine v5, AUTO MODE)

Paste into Claude Code in `boonz-erp`. Runs end-to-end without mid-run approvals: takes the recommended choices, self-runs Dara/Cody, skips what it cannot safely finish, applies green pieces (engine stays gated OFF), and reports anything incomplete at the end.

```
/goal Build PRD-042 (Refill v5 swap: slot-profile assortment pools) in AUTO MODE. Read docs/prds/PRD-042-swap-slot-profile-pools.md + PRD-040/039/037 + engines/refill/guardrails/*.md first. Supabase eizcexopcuoycuosittm. No em dashes. Forward-only, no edit-in-place, no _v2 parallel fns, no deletes. engine_add_pod FROZEN. PRD-041 is removed/abandoned; do not build it.

AUTO MODE (do not stop for me to edit or approve):
- Make every design choice from the PRD recommendation and CONTINUE. Never halt for sign-off.
- Use the STARTER lane-family grouping as-is: bottle={bottle_330,bottle_500,bottle_large}; can={can_250,can_330}; snack_small={bar_standard,pack_gum,date_ball}; bag={bag_snack,bag_large}; boxed={box_biscuit,cake_wrapped}; cup={cup_yogurt}; other={other}. Coverage must be 14/14; any unmapped physical_type -> 'other' and note it.
- Pool curation starts empty (derived-only); slot_pool_curation table exists for later use.
- Run Dara (design) and Cody (verdict) yourself as automated steps.
- If a piece cannot be completed (missing dependency, failing test, Cody BLOCK, data gap, replay error): SKIP just that piece, do NOT apply it, keep going with everything else, and record it for the final report.
- Apply green pieces to prod autonomously. INVARIANTS (never violate, even to "finish"): swaps_enabled stays false (never flip it); engine_add_pod byte-identical; no git push.

BUILD:
P0 data: physical_type_lane_family(physical_type PK, lane_family); slot_pool_curation(lane_family,shelf_size,boonz_product_id,mode in('include','exclude'),note); slot_profile_pool(lane_family,shelf_size,boonz_product_id,fill_qty,computed_at) PRECOMPUTED table + rebuild_slot_profile_pool() RPC (effective pool = derived[lane_family x size x product, fill_qty=floor(product_slot_capacity_units(physical_type,size)*0.85)] minus curation excludes plus includes; computed_at=now()) + pg_cron nightly BEFORE job 13. Run the first rebuild.
P1 engine engine_swap_pod v14 -> v15_slot_profile (forward CREATE OR REPLACE; Pass-3 rewrite only; passes 1/dead-tag/2b + kill switch unchanged): per band-3 eligible slot on a swaps-enabled gate-clean machine, resolve profile (incumbent physical_type->lane_family + planogram shelf_size; unresolvable->KEEP). pool = slot_profile_pool for the profile MINUS on-pod MINUS guardrail-blocked (_coexistence_blocks,_travel_scope_blocks,30-day intro cooldown,3x-suppressed) AND WH stock>seed. V = margin(landed-cost)*min(proj_vel*D, fill_qty); proj_vel=0.5*sister+0.3*global+0.2*affinity*global. KEEP unless best V>=keep_v*1.15. Assign greedy value-desc: <=2/machine, fleet<=10, no dup product/machine, homogenisation<=3 machines/product. qty_in=fill_qty clamped to WH; qty_out=current stock.

REPLAY (BEGIN..ROLLBACK, swaps forced true, gate-clean date, ADDMIND-1007 +1-2 machines), print PASS/FAIL + actual values:
 SP1 A08(cup)/A14(bottle)/A15(bag) pools only same-lane, no bar_standard.
 SP2 qty_in=profile fill_qty (no 25-bars-in-popcorn).
 SP3 no on-pod product in pool.
 SP4 curation include/exclude respected (synthesize a test row inside the rolled-back txn).
 SP5 winner=highest-V in-pool, beats keep x1.15; coexistence/TCCC/travel/dedup/homogenisation/rate-limits hold.
 SP6 slot_profile_pool.computed_at current; cron before job 13.
 R1 PRD-037 T1-T4/T7/T10-T13 hold; engine_add_pod byte-identical; swaps_enabled=false -> 0 Pass-3.

APPLY (auto, only the green pieces): P0 then P1; prod-confirm engine_version=v15_slot_profile + pool fresh; write docs/prds/PRD-042-EXECUTION-LOG.md; update CHANGELOG/RPC_REGISTRY/MIGRATIONS. No git push.

FINAL REPORT (always): (1) SP1-SP6 + R1 PASS/FAIL table with actual values; (2) applied y/n + timestamp per object; (3) ** INCOMPLETE / NEEDS CS ** - every piece skipped, assumed, failed, or Cody-flagged, with the reason, so I can investigate. Restate: swaps_enabled still false; lane grouping used the starter map (confirm/tweak later); PRD-040 Track D pilot unblocks only after this lands.
```
