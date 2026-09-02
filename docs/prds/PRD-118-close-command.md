/goal Close PRD-118 completely — ship the remaining tail, prove every door with a fixture, leave the repo clean. Repo: ~/Documents/Boonz Script and Data/BOONZ BRAIN/boonz-erp. Supabase project eizcexopcuoycuosittm.

READ FIRST: docs/prds/PRD-118-expiry-entry-and-bind-integrity.md including ADDENDUM 2 at the bottom (Addendum 2 wins on conflict), then `git log --oneline -15` to see what the 01-Sep loop already shipped.

## Already DONE — do not rework, do not re-apply

Items D (5 migrations), H (4), C (2), E §E-2, B (2), K (2), G1 (warehouse_expire_writeoff disposal-code fix) plus the two CENTRAL Activia write-offs already executed, and item I (code + docs). Item J is deliberately HELD for PRD-119 — its design is committed as docs (c756ae5); do NOT implement it, do not touch pod_inventory grain.

## NON-NEGOTIABLE RULES

Load `cody` before every migration and get a verdict; load `dara` before any schema change. Canonical RPCs only — never raw INSERT/UPDATE/DELETE on pod_refill_plan, refill_plan_output, refill_dispatching, slot_lifecycle, pod_inventory or warehouse_inventory (the writeoff/quarantine RPCs are the doors — use them). Every new function is SECURITY DEFINER with an explicit role check, a mandatory reason, and sets app.via_rpc / app.rpc_name — copy reactivate_warehouse_row as the reference. **Do NOT touch plan_date 2026-09-02 — it is live and being packed/delivered today — nor any live/future plan or dispatch rows.** Never downgrade an engine version. Never force-push; never reset/checkout-- over modified files.

## THE REMAINING TAIL, IN ORDER

**1. G2 — widen the `quarantined` generated column** (Dara design + Cody approval already given last session; re-confirm with Cody before applying since this is a fresh session):

- Pre-check FIRST: `SELECT indexdef FROM pg_indexes WHERE tablename='warehouse_inventory' AND indexdef ILIKE '%quarantined%'` — if any index exists on the column, recreate it identically inside the same migration after the ADD.
- Migration `prd118_g2_quarantine_generated_column`: DROP COLUMN quarantined; ADD COLUMN quarantined boolean GENERATED ALWAYS AS ((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY['unknown_pre_migration','dispatch_return_unverified','manual_quarantine']))) STORED. Table is ~1,500 rows — rewrite is cheap. Verify after: every previously-quarantined row is still quarantined (count before vs after must match exactly; no row uses 'manual_quarantine' yet).

**2. G3 — `set_wh_quarantine(p_wh_inventory_id, p_reason, p_caller_id, p_dry_run default true)`** as migration `prd118_g3_set_wh_quarantine`:

- Same role gate as release_wh_quarantine (warehouse / operator_admin / superadmin). Reason ≥10 chars. Refuses rows with warehouse_stock = 0 or status != 'Active' (nothing to hold back).
- Sets provenance_reason = 'manual_quarantine', but FIRST audits the prior provenance_reason value (write_audit_log) so provenance history is never silently destroyed.
- Before shipping, read release_wh_quarantine and confirm it correctly releases a 'manual_quarantine' row (what does it set provenance_reason to?). If it would leave the row in a state the generated column still counts as quarantined, fix release in the same migration and tell Cody.

**3. Execute the queued WH2-2001 write-offs** — the 4 expired batches totalling 22 units on WH2-2001, via warehouse_expire_writeoff with the proper disposal code, one call per row, reason naming the batch and expiry. Leave the Nescafe batches (exp 04–05 Sep, CENTRAL) untouched — CS accepts their expiry; they get written off only after they lapse. Report the exact rows and unit counts.

**4. Item F — find_substitutes_for_shelf v3** (migration prd118_f1): exclude candidates already on another shelf of the same machine unless that lane's runway < 7 days; exclude candidates dead on THIS machine (0 sales 30d on this machine); surface duplicate_on_machine / dead_on_machine / existing_lane_below_50pct flags in the Gate-1 diff output. Do not change ranking for candidates that pass the filters.

**5. Item A — goods receipt expiry integrity**: per-line expiry mandatory (no apply-to-all default in the receipt writer); warn — never block — when ≥2 lines of different products share an identical date; wire check_wh_expiry_anomaly / log_expiry_entry_suspect into receipt time; add boonz_products.typical_shelf_life_days (nullable) with a ±25% warning band at receipt. Dara for the column, Cody for each migration. If the receipt path is FE-heavy, ship the backend guards + a written FE spec and mark the FE part for the next session rather than rushing a half-tested UI change.

## FIXTURES — nothing counts as closed without proof

- Quarantine a CENTRAL batch via set_wh_quarantine (dry-run then real on a low-value test row) → assert v_wh_pickable excludes it and wh_fefo_for_line refuses to pin it → release it → assert it is pickable again.
- Write off a fixture-created expired row via warehouse_expire_writeoff → assert disposal_reason recorded and stock zeroed.
- F: run find_substitutes_for_shelf on a machine where the top candidate already sits on another shelf → assert the flag fires and the diff surfaces it.
- A: insert a test receipt with two different products sharing one date → assert the warning logs; a receipt line without expiry → assert refusal.
- Re-run the two nightly assertions shipped 01-Sep (sentinel-bindable, over-commit) once each and confirm both return clean.

## REPO HYGIENE — part of closing

- `git status` currently shows untracked supabase/migrations/20260901124724_prd118_g1_*.sql, docs/prds/PRD-118-expiry-entry-and-bind-integrity.md, docs/prds/PRD-118-goal-command.md — commit them with the new work.
- src/app/(field)/field/packing/[machineId]/page.tsx has an UNCOMMITTED modification of unknown origin: `git diff` it FIRST and show me the hunks in the report. If it is leftover intentional PRD-118 work, commit it with an honest message; if you cannot tell what it is, leave it uncommitted and flag it — never discard it.
- Update docs/architecture/CHANGELOG.md, MIGRATIONS_REGISTRY.md, RPC_REGISTRY.md, METRICS_REGISTRY.md for EVERYTHING PRD-118 shipped (01-Sep loop + this tail) — one pass, complete. Then append a "PRD-118 CLOSED" section to the PRD with the final ledger.
- Commit in logical chunks, push to origin main (plain push; if rejected, pull --rebase and stop on any conflict to show me).

## STOP CONDITIONS

Stop and write up rather than force: anything that would touch the 2026-09-02 plan or any live dispatch row; any schema decision Cody rejects; any fixture that fails twice. Carry on with the rest.

## CLOSE-OUT REPORT

The final A–K ledger with one line of live evidence per item (migration name / fixture result / commit sha), the Cody verdict per migration, the exact WH2 write-off rows and unit totals, what J is waiting on (PRD-119), the packing-page diff verdict, and confirmation that git status is clean and pushed.
