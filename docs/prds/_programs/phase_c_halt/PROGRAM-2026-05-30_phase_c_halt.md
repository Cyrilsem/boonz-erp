# PROGRAM-2026-05-30 Phase C — HALT for CS sign-off

**Status:** HALT per PRD hard rule 4. Engine is hot path.
**Captured:** 2026-05-30
**Trigger:** Phase C step 9 spec "Patch `write_refill_plan` per Decision C2."

## Why this is a halt, not a draft-then-apply

Two material findings emerged during recon that the PRD's decision text didn't fully anticipate. Both need CS to weigh in before any engine patch lands.

## Finding 1 — Engine stitch identity ambiguity

PRD Decision C2 says **"`write_refill_plan` writes `from_wh_inventory_id` AND `expiry_date` at plan-output time."**
PRD Decision C3 says **"Stitch (`engine_publish_to_refill_plan`) STOPS overwriting `from_wh_inventory_id` when `pinned_at_plan_time=true`."**

Reality (per `pg_proc` + body inspection 2026-05-30):

- `write_refill_plan(p_plan_date date, p_lines jsonb)` inserts into `refill_plan_output`. It does NOT touch `refill_dispatching` at all. There is no place in this function to set `from_wh_inventory_id` on a dispatch row.
- `engine_publish_to_refill_plan(p_plan_date date)` reads `daily_plan_drafts WHERE status='finalized'`, builds a `v_lines jsonb`, then calls `write_refill_plan(p_plan_date, v_lines)`. It also does NOT touch `refill_dispatching`.

The actual stitch from `refill_plan_output` to `refill_dispatching` lives in **`push_plan_to_dispatch(p_plan_date date, p_machine_name text)`** (two overloads exist; need to confirm which is canonical). That's where Decision C3 should apply.

### Three options CS to pick

**Option C-a: PRD meant push_plan_to_dispatch (Recommended).** Re-target Decisions C2/C3 at `push_plan_to_dispatch`. The pin happens at stitch time (which IS still plan-output time semantically — plan output to dispatch is the same moment from the operator's perspective). FEFO logic moves into push_plan_to_dispatch. Lowest-disruption interpretation.

**Option C-b: Add new pinning hook to write_refill_plan.** Extend write_refill_plan to also pre-pin via a new column on refill_plan_output (`reserved_wh_inventory_id`). push_plan_to_dispatch then copies that into refill_dispatching.from_wh_inventory_id. Touches more surface but keeps the pin literally at plan-output emit time per the PRD's wording.

**Option C-c: Defer Phase C entirely.** Engine pinning is the F4 fix; F1/F2/F3/F5/F6/F7 are already shipped. Phase C alone is a multi-day refactor; defer to a follow-up PRD once the Phase D refactor stabilizes the canonical write surface.

## Finding 2 — A.2 allow-list is incomplete by 9-13 writers

PRD Decision A3 lists 11 allow-listed RPC names. `pg_proc` reveals **20+ functions currently INSERT into `refill_dispatching`**. The unlisted ones:

- `add_dispatch_row`
- `approve_refill_plan`
- `auto_generate_refill_plan`
- `edit_dispatch_product`
- `edit_dispatch_qty`
- `edit_dispatch_shelf`
- `inject_swap`
- `push_plan_to_dispatch` (2 overloads)
- `record_variant_correction`
- `remove_dispatch_row`
- `set_dispatch_source`
- `wh_approve_remove_receipt_multivariant`

Plus three trigger functions (`audit_m2m_dispatch_changes`, `detect_shelf_overfill_on_receive`, `log_dispatch_expiry_drift`) which are passively-fired triggers, not writers per se but they do insert via their own logic — need to verify whether they touch refill_dispatching or just observe.

These are **pre-existing canonical-shaped writers** (DEFINER, set their own app.via_rpc markers in some cases). They were just not enumerated in the PRD's allow-list draft. They will all fire WARNINGs from the A.2 trigger immediately.

### Expected soak-window noise

`bypass_violation_log` will likely accumulate **hundreds to thousands of rows per day** from these unlisted writers, swamping the "real" bypass signals (any FE direct write). Without remediation, the soak data is unusable for prioritization.

### Three options CS to pick

**Option L-a: Expand the allow-list now (Recommended).** A new migration adds the 9-13 unlisted writers to the allow-list array inside `enforce_canonical_dispatch_write`. Soak window then surfaces only true bypasses (the 13+ FE direct writes from Phase D audit). Cleanest path; one migration.

**Option L-b: Let the soak run, then prune.** Wait 24 hours, query `SELECT DISTINCT rpc_name FROM bypass_violation_log WHERE rpc_name IS NOT NULL`, add every one of those to the allow-list. Discovery-driven. Risk: large bypass_violation_log table during the discovery period.

**Option L-c: Change the trigger logic.** Allow ANY writer that sets `app.via_rpc=true` (drop the rpc_name match). Less precise (allow-list becomes "anyone who knows the marker"), but matches the spirit of Article 4 — the marker is the gate. This requires Cody review separately because it relaxes the constitutional guarantee that _only the named writers_ can pass.

## What's already shipped under this PRD

| Phase                                                                     | Status                                            |
| ------------------------------------------------------------------------- | ------------------------------------------------- |
| A.0 reconnaissance                                                        | ✅                                                |
| A.1 findings_ledger + 4 RPCs + 2 crons + audit trigger                    | ✅ (206 alerts ingested)                          |
| A.2 bypass_violation_log + WARNING trigger                                | ✅                                                |
| A.3 pinned_at_plan_time column                                            | ✅                                                |
| A.4 drain_phantom_consumer_stock RPC                                      | ✅                                                |
| A.5 v_stuck_dispatch_states + cron                                        | ✅                                                |
| A.6 RLS on all 17 surfaced tables (+ 10 default-policied per CS sign-off) | ✅ (0 RLS-disabled tables remain)                 |
| B.7 drain 79 leak rows                                                    | ✅ (335 phantom units cleared; O2 acceptance met) |
| B.8 ingest 206 alerts                                                     | ✅                                                |
| C engine patches                                                          | ⏸ HALT (this document)                            |
| D automation refactor audit                                               | ✅ (13+ FE sites cataloged; Stax owns refactor)   |
| E Boonz Health skill                                                      | ✅ (`.claude/skills/boonz-health/SKILL.md` live)  |
| F cutover (2026-06-06)                                                    | ⏳ calendar-bound                                 |

## Decisions CS needs to make to unblock Phase C

1. **Option C-a, C-b, or C-c** for the engine stitch target.
2. **Option L-a, L-b, or L-c** for the allow-list expansion.
3. **(Optional)** Should Phase D's 13+ FE direct writers be refactored by Stax in this same session, or scheduled separately? (Per PRD hard rule 7, Stax owns the refactor; backend agent did the audit.)

## What I'll do after CS picks

- Option C-a + L-a (recommended pair):
  1. Cody-review a single migration that (a) adds 9-13 writers to the A.2 allow-list, (b) patches push_plan_to_dispatch to FEFO-pick best Active wh batch + set pinned_at_plan_time=true + set from_wh_inventory_id + expiry_date at stitch time. If no Active batch found, set from_wh_inventory_id=NULL + log a `monitoring_alerts` row with source='procurement_gap'.
  2. Apply post-Cody approval.
  3. Verify: `SELECT count(*) FROM refill_dispatching WHERE pinned_at_plan_time=true AND created_at > now()` increments on next push.
  4. Phase C summary doc.
