-- PRD-UNIFY Step 1 (Dara design) — persist the single blended refill decision on the draft row.
--
-- DARA: pod_refill_plan is the committed draft (one row per machine×shelf×plan_date). The card and the
-- diff must read the SAME decision the engine writes — so we store the decision jsonb on the row
-- (auditable, diffable) AND expose compute_refill_decision(...) (Step 2) for live/preview rendering.
-- Rejected alternative: recompute independently in the FE (that is how we got "two brains").
--
-- The jsonb shape (one source of truth for BOTH target_units AND final_score):
--   { stance, cover_mult, floor_pct, velocity, days_cover, velocity_target, visual_target,
--     target_units, refill_qty, runway_days, global_badge, local_badge, units_7d, final_score,
--     reasoning:{ demand_base, stance_mult, placement_mult, urgency_mult, units_15d, capacity,
--                 current_stock, velocity_7d, velocity_30d } }
--
-- CODY verdict (design): ⚠️ Approve with revisions → all cleared here.
--   Article 1  — additive column; the decision is WRITTEN only by the engine writer path (Step 3 fills it
--                via engine_finalize_pod propagation; see Step 3 file). The card never computes its own
--                target — this removes the second authority (the whole point). ✅
--   Article 8  — pod_refill_plan already carries tg_audit_pod_refill_plan (AFTER INSERT/UPDATE/DELETE),
--                so any write of `decision` is audited. No new audit infra needed. ✅
--   Article 12 — forward-only `ADD COLUMN IF NOT EXISTS`; no DROP, no table edit-in-place. ✅
--   Article 14 — evolve pod_refill_plan in place; NO _v2/parallel table. ✅
--   Article 4  — N/A here (no function); the writers that set it (Step 3) keep their GUC/role/validation.
--
-- Nullable + defaulted NULL: existing rows keep NULL until the next engine run rewrites them; the reader
-- (Step 4) falls back to live compute_refill_decision when decision IS NULL, so no backfill is required.
-- APPLY NOTHING — this is a file for CS review.

ALTER TABLE public.pod_refill_plan
  ADD COLUMN IF NOT EXISTS decision jsonb;

COMMENT ON COLUMN public.pod_refill_plan.decision IS
  'PRD-UNIFY: the single blended refill decision (lifecycle stance + recency dosage). The machine card and RefillPlanningTab render this; there is no competing health verdict. Written by the engine path (engine_add_pod -> engine_finalize_pod) and mirrored live by compute_refill_decision(machine_id, shelf_id, boonz_product_id, days_cover).';
