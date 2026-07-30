# /goal — PRD-107 Pack Stage: Remove Legs + Progress Truth

GOAL: Make the packing board tell the truth and stop stranding machines at "Mark All Packed" when only Remove legs are unpacked. Read PRD-107-pack-stage-remove-legs-and-progress-truth.md first. Supabase eizcexopcuoycuosittm. Stax implements FE, Dara designs the constraint/view, Cody review MANDATORY before apply.

WHY (incident 2026-07-29, recurring since NOOK 07-20): Warehouse packed everything packable on HUAWEI-2003 (27/28) and MC-2004 (32/39) but FE stayed on "Mark All Packed". Verified root cause: confirm_machine_packed excludes Remove legs from its unresolved check (action IN ('Refill','Add New','Add')) but the FE progress denominator COUNTS them — FE/backend divergence. Plus: 10 rows sat packed=true with pack_outcome NULL (no consistency constraint), and MC A15's REMOVE legs would have emptied the shelf because the paired ADD_NEW went not_filled (orphaned swap leg, no guard).

BUILD:

1. View public.v_dispatch_pack_progress(machine_id, dispatch_date) → total_included, packable_n (Refill/Add New/Add only), resolved_n (packed|partial|not_filled|skipped|no_pack_needed), driver_action_n (Remove/M2W/M2M-source legs), orphaned_swap_legs jsonb, ready_to_pack_close bool. This is THE single source of truth. Rewrite confirm_machine_packed's unresolved check to read it (no logic duplication).
2. New pack_outcome enum value 'no_pack_needed'. push_plan_to_dispatch stamps it on every line whose action draws nothing from WH (Remove, Machine To Warehouse, M2M source leg) at push time. Migration backfills historical rows (packed=true AND pack_outcome IS NULL → 'no_pack_needed' where action is a driver-side leg, else 'packed').
3. Constraint (trigger or CHECK): packed=true ⇒ pack_outcome IS NOT NULL. Apply after backfill.
4. Orphaned swap-leg guard in confirm_machine_packed(final=true): for each shelf_id with a REMOVE line AND an ADD_NEW line where the ADD_NEW ended not_filled or skipped, set needs_review=true, review_reason='orphaned_swap_leg' on the REMOVE and return them in the response under 'orphaned_swap_legs' with a proposed action (skip to keep shelf stocked). NEVER auto-skip silently — surface for one-tap accept in FE.
5. Driver manifest: audit the driver app query (Stax) — line inclusion must depend ONLY on include/cancelled/skipped, never packed/pack_outcome, so Remove legs reach the machine even when pack-closed around them.
6. FE board (Stax): progress bar = resolved_n/packable_n from the view, Remove legs shown as '+N driver actions' (not in the bar); 'Mark All Packed' enabled by ready_to_pack_close; orphaned-swap-leg banner with accept-skip button. Kill the client-side denominator.

GUARDRAILS: No raw DML on refill_dispatching outside sanctioned RPCs; packed/picked-up rows stay locked (protect_packed_dispatch_row untouched); do not change skip_dispatch_line semantics; Title Case dispatching actions; enum addition via migration with Cody sign-off; backfill in the same migration, constraint enabled only after backfill verifies zero violations.

ACCEPTANCE:

- Replay 07-29 MC-2004 state: view returns packable 32, resolved 32, driver_action_n 7, ready_to_pack_close true; confirm_machine_packed(final) succeeds; A15 REMOVE flagged orphaned_swap_leg in response.
- Zero rows fleet-wide with packed=true AND pack_outcome IS NULL after migration; constraint blocks new ones.
- Driver app shows Remove legs for a pack-closed machine (test JET A15 Leibniz REMOVE).
- FE board and confirm_machine_packed can never disagree (both read v_dispatch_pack_progress; pgTAP parity test).
- pgTAP: orphan-pair detection incl. multi-line ADD_NEW splits; no_pack_needed stamped at push for Remove/M2W/M2M-source.
- EXECUTION-LOG at boonz-erp/docs/prds/PRD-107-EXECUTION-LOG.md; Cody verdict recorded before apply.
