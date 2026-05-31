---
id: PRD-015
title: Refill pipeline reliability + machine include/exclude toggle
status: Draft
severity: P1
reported: 2026-05-30
source: >
  CS request to "relook at the brain of boonz-master-3 and fine tune" after errors and
  inconsistent results on the 2026-05-31 planning run. Triggered by the
  Boonz_Fleet_Diagnostic_Report_2026-05-30.docx, whose headline claims were found to be
  fabricated on live-DB verification (see Context). This PRD captures the four REAL issues.
routing: [Dara, Cody, Stax, refill-brain, boonz-pico-refill-pm, boonz-pico-stitch]
protected_entities:
  [machines_to_visit, pod_inventory, pod_inventory_audit_log, pod_refill_plan, planned_swaps]
related:
  - PRD-010 (engine v11 signal-aware floor; AC#5 picker auto-close)
  - PRD-014 (pod_inventory inline adjust canonical writer)
  - migration phaseF_fix_auto_generate_draft_picker_contract (2026-05-30, Issue 1 Bug 1 — already shipped)
  - memory: project_diagnostic_report_2026-05-30_findings, bug_auto_generate_draft_double_bug,
    feedback_cron_keep_human_confirm, project_pod_inventory_staleness_swapped_shelves
---

# PRD-015 — Refill pipeline reliability + machine include/exclude toggle

## Context — why this PRD exists, and what it deliberately does NOT do

The `Boonz_Fleet_Diagnostic_Report_2026-05-30.docx` reported that 96% of fleet shelves
(330 / 343) had a `pod_inventory` vs WEIMI mismatch and recommended, as a P0, force-overwriting
`pod_inventory.boonz_product_id` from WEIMI across 20 machines.

That report was verified against the live DB (`eizcexopcuoycuosittm`) and **its central claims do
not hold**:

- The mismatch query string-compared WEIMI `goods_name_raw` against canonical `pod_product_name`
  and joined on incompatible shelf-code formats (`A04` vs `0-A04`) — both produce false positives
  at scale, and `v_live_shelf_stock` already exposes a resolved `pod_product_id` the report ignored.
- The case-study machines do not exist: "OMDCW-1056" is really `OMDCW-1021`; "OMDBB-1055" is
  `OMDBB-1020`; "HUAWEI-1009" and "GRIT-1018" are not in the fleet. The shelf-by-shelf table is
  fabricated.
- True fleet state: **319 / 343 shelf rows resolve `direct`; only 14 are genuinely `unmatched`**,
  all of them Plaay-campaign products.

**This PRD therefore explicitly rejects the report's blind 20-machine `pod_inventory` overwrite.**
It instead addresses the four real issues uncovered during verification. All `pod_inventory`
work here is targeted, reversible (archive, never DELETE), and gated on operator confirmation per
Constitution Articles 1 and 6 and the standing "no destructive changes without per-row diff"
directive.

---

## Problem

### Issue 1 — The nightly draft cron cannot produce a draft (errors + inconsistent results)

The 8pm Dubai cron `phaseF_stage1_prep_8pm_dubai` (cron job 13) runs
`auto_generate_draft(CURRENT_DATE + 1)`, which chains
`pick_machines_for_refill` → `engine_add_pod` → `engine_swap_pod`. Two distinct defects:

- **Bug 1 — picker return-contract mismatch (SHIPPED 2026-05-30).**
  `pick_machines_for_refill` is live at **v6** and `RETURNS TABLE(...)`, but `auto_generate_draft`
  assigned its result to a `jsonb` scalar (`v_pick_result := pick_machines_for_refill(...)`) and
  read `v_pick_result->>'machines_picked'`. Coercing a record to jsonb raised
  `invalid input syntax for type json`, killing the cron at the picker stage. Fixed via migration
  `phaseF_fix_auto_generate_draft_picker_contract` (`SELECT COUNT(*) INTO v_picked_count FROM
pick_machines_for_refill(...)`). Cody-approved. Documented here for completeness; **no further
  action required for Bug 1.**

- **Bug 2 — re-pick wipes the Gate-0 confirmation it then requires (OPEN).**
  `engine_add_pod` calls `_assert_gate_zero`, which refuses if any picked machine lacks
  `confirmed_at`. But `pick_machines_for_refill`'s `INSERT ... ON CONFLICT` sets
  `confirmed_at = NULL`, and `auto_generate_draft` re-runs the picker immediately before calling
  the engine. The sequence is therefore unwinnable: every run fails Gate 0 with
  "machines picked but unconfirmed". This is why no draft has auto-generated.

**Decision (CS, 2026-05-30):** keep an explicit **human confirm** step before the engine runs;
do NOT auto-confirm machines inside any cron (see memory `feedback_cron_keep_human_confirm`).
The fix is to decouple picking from the engine build so the engine only ever runs on
machines a human has confirmed — never re-picking inside the engine-build path.

### Issue 2 — `pod_inventory` product identity is stale on physically-swapped shelves

`engine_add_pod` reads `pod_inventory` for shelf product **identity** and `v_live_shelf_stock`
for stock **levels**. On ~14 shelves where the Plaay campaign (launched 2026-05-13) was physically
swapped in, `pod_inventory` was never updated, so it still names the old product. Verified examples:

- `OMDCW-1021` A07 — `pod_inventory` says "Krambals"; shelf physically holds Plaay Truffle at 8%
  fill. Engine planned **nothing** → real missed refill on a near-empty shelf.
- `OMDCW-1021` A06 — `pod_inventory` says "Popit/Hunter"; shelf physically holds Plaay Tablet.
  Engine planned a REFILL of the **wrong product** → ghost refill.

Compounding data-integrity defect: several shelves carry **multiple `Active` `pod_inventory`
rows** (e.g. `NOVO-1023` A03 had 8 active rows; `MC-2004` A06 had Santiveri + SF Pancake + Plaay
Truffles). A shelf should have exactly one active product; the fan-out distorts every engine read.

Scope is ~14 swapped shelves plus the multi-active-row shelves — NOT the 343 the report claimed.

### Issue 3 — No launch gate and no unmatched-product alert (the systemic root cause)

The Plaay launch deployed products physically with **zero** name mapping
(`product_name_conventions`) and never seeded `pod_inventory`. The pipeline then degraded silently:
`v_live_shelf_stock` marked the shelves `unmatched` (NULL `pod_product_id`), so the engine was
blind to them, the picker's auto-close (`pick_machines_for_refill` v6 AC#5) could not fire because
the "add" product never resolved, and 15 `planned_swaps` sat `pending` for over two weeks. **Nothing
alerted.** This single gap produced every symptom in the diagnostic report. The blind spot was
closed manually on 2026-05-30 (three `product_name_conventions` rows added; 10 of 17 stale swaps
then auto-closed), but the class of failure will recur on the next launch unless gated.

### Issue 4 — No way to scope the refill list to the machines being visited today (NEW feature)

`/refill` (RefillPlanningTab) shows every machine the picker selected (typically 20–30). CS needs
to choose a subset for a given day's route (e.g. 5 machines for a Sunday run) without deleting
rows from `machines_to_visit` (which loses picker data) and without committing refills for
machines that will not be visited. There is currently no include/exclude control, so the list is
cluttered and the commit scope cannot be narrowed.

---

## Acceptance Criteria

### Issue 1 — Decouple picking from the engine build (human-confirm flow)

**AC#1 — New engine-build orchestrator that never re-picks.**
Create `build_draft_for_confirmed(p_plan_date date) RETURNS jsonb` (SECURITY DEFINER, Article 4
`app.via_rpc`/`app.rpc_name`, role check `operator_admin`/`superadmin`/`manager`). It:

1. Asserts Gate 0 via `_assert_gate_zero(p_plan_date)`. If it fails, returns
   `{status:'awaiting_confirmation', confirmed:0, picked:N}` — a clean status, **not** an error.
2. Runs `engine_add_pod(p_plan_date, 14)` then `engine_swap_pod(p_plan_date, 2, 0.30, 14)` over the
   confirmed machines only.
3. Returns the same `draft_ready` shape `auto_generate_draft` returns today.

It does **not** call `pick_machines_for_refill`. Picking remains the morning cron (job 14) and/or
an operator action.

**AC#2 — Cron job 13 repointed.**
`phaseF_stage1_prep_8pm_dubai` calls `build_draft_for_confirmed(CURRENT_DATE + 1)` instead of
`auto_generate_draft`. If no machines are confirmed, the cron logs `awaiting_confirmation` and
exits cleanly (no error noise, no partial state). `auto_generate_draft` is retained for explicit
manual "pick + confirm + build in one shot" use only, and its header comment documents that it
re-picks (and therefore must not be wired to a cron under the human-confirm model).

**AC#3 — Confirmation is the human gate, surfaced in the FE.**
The operator confirms the route via `confirm_machines_to_visit(p_plan_date)`. The FE exposes this
as part of the Issue 4 toggle flow (confirming = "lock my selected machines for tonight's build").
No cron, trigger, or n8n flow may call `confirm_machines_to_visit` (Article 11; memory
`feedback_cron_keep_human_confirm`).

### Issue 2 — Targeted, reversible `pod_inventory` reconciliation

**AC#4 — Mismatch detection view.**
Create `v_pod_inventory_shelf_mismatch` comparing, per `(machine_id, shelf_id)`, the `Active`
`pod_inventory` product (mapped to `pod_product_id` via `product_mapping` global default) against
`v_live_shelf_stock.pod_product_id`, using the resolved IDs on both sides (never raw-name compare)
and de-duplicating fan-out with `DISTINCT ON`. Columns: machine, shelf, pod_inventory product,
WEIMI-resolved product, fill_pct, active_row_count, verdict
(`product_mismatch` | `multi_active_rows` | `no_pod_row` | `weimi_unmatched` | `ok`).

**AC#5 — Canonical reconciliation writer (archive, never DELETE).**
Create `reconcile_pod_inventory_shelf(p_machine_id uuid, p_shelf_id uuid, p_new_pod_product_id
uuid, p_reason text, p_confirm boolean DEFAULT false)` (SECURITY DEFINER; Article 4; writes
`pod_inventory_audit_log` via the standard trigger). With `p_confirm=false` it returns the per-row
diff (rows to archive, row to seed) and writes nothing. With `p_confirm=true` it: archives all
current `Active` rows on the shelf via `status='Inactive'`,
`removal_reason='archived_<date>_reconcile_weimi'` (no DELETE — see
`reference_pod_inventory_archival_pattern`), then inserts one `Active` row for
`p_new_pod_product_id`. Refuses if the shelf has a linked `refill_plan_output` row past `pending`.

**AC#6 — One-active-row-per-shelf integrity.**
Add a partial unique index `uniq_active_pod_per_shelf` on `pod_inventory (machine_id, shelf_id)
WHERE status = 'Active'`. Before adding it, AC#5 must resolve existing multi-active shelves
(operator-confirmed, per-row diff). Index creation is a separate migration that runs only after
the data is clean.

**AC#7 — One-time scoped reconciliation for the 14 Plaay shelves.**
Using AC#4 + AC#5, reconcile only the shelves in `v_pod_inventory_shelf_mismatch` whose
WEIMI-resolved product is a Plaay product. Each shelf reconciled individually with the diff shown
to CS and explicit sign-off. No machine-wide or fleet-wide bulk operation.

### Issue 3 — Launch gate + unmatched-product alert

**AC#8 — Launch-readiness gate on new products.**
Create `assert_product_launch_ready(p_pod_product_id uuid, p_expected_weimi_names text[])
RETURNS jsonb`. Returns ready/blocked with the specific missing pieces: (a) at least one
`product_mapping` row for the pod product totaling 100% split, and (b) a `product_name_conventions`
row (or direct/case-insensitive match) for every name in `p_expected_weimi_names`. Wire it as a
precondition in the `planned_swaps` insert path used by `boonz-pico-upstream` / launch tooling: a
swap that introduces a product failing this gate is rejected with the missing-mapping detail.

**AC#9 — Daily unmatched-WEIMI alert.**
Create `cron_unmatched_weimi_alert() RETURNS jsonb` that scans `v_live_shelf_stock` for
`match_method = 'unmatched' AND is_eligible_machine = true` and writes one finding per distinct
`goods_name_raw` into the existing findings ledger (reuse the `phantom_pod_alert` / findings-ledger
infrastructure — cron jobs 18/20). Schedule daily. Acceptance: a product physically deployed
without a mapping surfaces within 24h instead of two weeks.

### Issue 4 — Per-machine include/exclude toggle on `/refill`

**AC#10 — Data model.**
`ALTER TABLE machines_to_visit ADD COLUMN is_included boolean NOT NULL DEFAULT true;`
`pick_machines_for_refill`'s `ON CONFLICT` branch must set `is_included = true` (reset to included
on every fresh pick for a new `plan_date`), consistent with how it already resets `confirmed_at`.

**AC#11 — Toggle RPCs (canonical writers).**
`set_machine_inclusion(p_plan_date date, p_machine_id uuid, p_is_included boolean) RETURNS jsonb`
and `bulk_set_machine_inclusion(p_plan_date date, p_is_included boolean) RETURNS jsonb`
(SECURITY DEFINER; Article 4; role-checked). No direct FE writes to `machines_to_visit`
(Article 3). Address machines by `machine_id`, not name.

**AC#12 — Engine/commit honor inclusion.**
`build_draft_for_confirmed` (AC#1), `engine_add_pod`, `engine_swap_pod`, `engine_finalize_pod`,
and `stitch_pod_to_boonz` process only machines where `is_included = true` for the plan_date.
Excluded machines remain in `machines_to_visit` (not deleted) and are skipped by the commit chain.

**AC#13 — FE behavior (RefillPlanningTab).**
Each machine card gets a checkbox in its header (default checked). Unchecked machines: collapse to
a compact single-line row, drop to the bottom under a collapsible "Excluded (N)" section, render
de-emphasized (reduced opacity, grey). Top bar shows "N of M machines selected" plus
"Include all" / "Exclude all". The Commit button reads "Commit (N machines)" and is disabled with a
tooltip when N = 0. Toggling persists optimistically and syncs via `set_machine_inclusion`. Sorting:
included first (severity desc), then the excluded collapsible. This is the explicit human confirm
gate from AC#3 — committing the included set confirms it.

### Cross-cutting — role tiers (day-of edit empowerment)

**Decision (CS, 2026-05-30):** planning stays with the operator; the warehouse manager is
empowered to **edit** the plan on refill day when physical inventory is messed up, but does NOT
plan/confirm it.

- `set_machine_inclusion` / `bulk_set_machine_inclusion` (AC#11) → `operator_admin` / `superadmin`
  / `warehouse`. (`manager` dropped — no such users exist.)
- `confirm_machines_to_visit` and `build_draft_for_confirmed` (AC#1) stay `operator_admin` /
  `superadmin`. Warehouse cannot plan/confirm. If she hits a wall, widening these is the activate-later fix.

**AC#14 — grant `warehouse` execute on the day-of edit RPCs.**
Widen the role check on `edit_pod_refill_row`, `stop_pod_refill_row`, and `restitch_after_edits`
to include `warehouse` (alongside the existing `operator_admin` / `superadmin`). `restitch_after_edits`
currently hard-codes `role = ANY(ARRAY['operator_admin','superadmin'])` — add `'warehouse'`.
`find_substitutes_for_shelf` already allows warehouse (read-only) — no change. These are existing
canonical writers on `pod_refill_plan`; this is a role-tier widening only (no logic change), so the
`operator_status`/locked-row guards still protect packed/dispatched rows. Cody review required
(Articles 1, 4). Without this, the warehouse manager can view substitutes but cannot change a qty,
stop a row, or re-push — the empowerment above would not function.

---

## Data model changes

| Table               | Change                                                                                        | Migration                                                 |
| ------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| `machines_to_visit` | `+ is_included boolean NOT NULL DEFAULT true`                                                 | `phaseF_mtv_is_included`                                  |
| `pod_inventory`     | partial unique index `uniq_active_pod_per_shelf (machine_id, shelf_id) WHERE status='Active'` | `phaseF_pod_one_active_per_shelf` (after AC#5/#7 cleanup) |

No new tables (Article 14). Reconciliation and inclusion both evolve canonical tables forward.

## RPC / function summary

| RPC                                                       | Type                | Issue | Notes                                                         |
| --------------------------------------------------------- | ------------------- | ----- | ------------------------------------------------------------- |
| `build_draft_for_confirmed(date)`                         | writer/orchestrator | 1     | engine build over confirmed+included machines; never re-picks |
| `v_pod_inventory_shelf_mismatch`                          | view (read)         | 2     | resolved-ID comparison, fan-out de-duped                      |
| `reconcile_pod_inventory_shelf(uuid,uuid,uuid,text,bool)` | writer              | 2     | archive-then-seed; `p_confirm=false` = diff only              |
| `assert_product_launch_ready(uuid,text[])`                | read/guard          | 3     | blocks unmapped product launches                              |
| `cron_unmatched_weimi_alert()`                            | writer (ledger)     | 3     | daily unmatched-WEIMI finding                                 |
| `set_machine_inclusion(date,uuid,bool)`                   | writer              | 4     | per-machine toggle                                            |
| `bulk_set_machine_inclusion(date,bool)`                   | writer              | 4     | include/exclude all                                           |

## Non-functional requirements

- Every new/changed DEFINER writer sets `app.via_rpc`/`app.rpc_name`, validates role and inputs,
  and audits via the standard trigger (Articles 4, 8).
- All migrations forward-only (Article 12); no parallel `_v2` tables (Article 14).
- `pod_inventory` writes are archive-only; no DELETE, no silent quantity reductions; per-row diff
  before any apply.
- `build_draft_for_confirmed` completes within the engine's current envelope (engine_add ~0.6s,
  engine_swap ~1.9s observed on 2026-05-31).

## Edge cases & error handling

- **No confirmed machines at 8pm** → `build_draft_for_confirmed` returns `awaiting_confirmation`;
  cron logs and exits 0. No partial draft.
- **All machines excluded** → commit disabled in FE; `build_draft_for_confirmed` returns
  `no_included_machines`.
- **Reconciliation target shelf already past `pending`** → `reconcile_pod_inventory_shelf` refuses
  (physical commitment locked).
- **WEIMI product still unmatched at reconcile time** → AC#5 refuses to seed a NULL product; the
  fix is a `product_name_conventions` row first (Issue 3 gate).
- **Picker re-runs after inclusion set** → `is_included` resets to true for the new pick; documented
  as intended (a fresh pick is a fresh route).

## Out of scope

- The diagnostic report's fleet-wide `pod_inventory` overwrite (rejected — see Context).
- Shelf-level (sub-machine) refill ticking — CS chose per-machine granularity. Deferred.
- Shelf capacity expansion / planogram re-layout (tracked under PRD-010 Issue 4 follow-ups).
- Auto-confirming machines in cron (explicitly rejected by CS).
- Cabinet-aware `v_live_shelf_stock` SPLIT_PART JOIN hardening for multi-cabinet machines
  (separate known item).

## Open questions

1. Should `cron_unmatched_weimi_alert` (AC#9) also auto-create a draft `product_name_conventions`
   proposal for operator approval, or only alert? Default: alert only.
2. For the launch gate (AC#8), do we hard-block the `planned_swaps` insert, or allow insert with a
   `blocked_unmapped` status that the picker skips until mapped? Default: hard-block.
3. Should excluded machines (AC#12) still receive a `pick_machines_for_refill` health refresh the
   next morning, or stay excluded until re-picked? Default: re-picked fresh (is_included resets).

## Routing & review

- **Dara** — `machines_to_visit.is_included`, the partial unique index, and
  `v_pod_inventory_shelf_mismatch` shape.
- **Cody** — mandatory review for every writer touching `pod_inventory`, `machines_to_visit`,
  `pod_refill_plan`, `planned_swaps` (Articles 1, 4, 6, 8, 12).
- **Stax** — `build_draft_for_confirmed`, cron job 13 repoint, the toggle RPCs, and the
  RefillPlanningTab FE.
- **refill-brain / boonz-pico-refill-pm / boonz-pico-stitch** — engine and stitch `is_included`
  filtering.
