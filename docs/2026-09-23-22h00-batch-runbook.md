# 22:00 Dubai batch runbook, 2026-09-23

Prepared 2026-09-23 08:00-ish Dubai. Do not run any step before 22:00 Dubai. Report the time at
the start of execution and after each step. No em dashes.

## Pre-flight (already true, verified today, re-confirm at go-time)

- All 7 originally-planned PRD-130 migrations (01, 02, 05, 06, 08, 09, 10) are already applied to
  prod and recorded in `supabase_migrations.schema_migrations`. Nothing new to apply for those.
- `push_plan_to_dispatch` proof table (the step-1 gate from CS's "Direction" message) is already
  green from earlier testing this session against WAVEMAKER, plan_date 2031-02-02: every
  Refill/Add New = warehouse_fill with from_warehouse_id set, every Remove = warehouse_return with
  return_warehouse_id set and from_warehouse_id NULL, no NULL kinds. prd131_02 is cleared to apply.
- F3 (prd131_03, packing-by-kind) and the `prd131-packing-screen` branch are explicitly NOT part
  of tonight's batch. Keep that branch unpushed until F3 is live in prod, per CS.

## Step 1: A5, PRD-130 close

1. Apply `supabase/migrations/20260923040000_prd130_03_intra_machine_receive_no_wh_touch.sql` to
   prod (`receive_dispatch_line` intra-machine fix). Tested green 2026-09-23 in a rolled-back
   transaction.
2. Apply `supabase/migrations/20260923040100_prd130_04_split_inherits_parent.sql` to prod
   (`conserve_split_dispatch_quantity` inherits-parent fix). Tested green 2026-09-23.
3. Run PRD-130 acceptance checks 1-6 (`docs/PRD-130-dispatch-edit-paths.md` section 5) against
   live data or a synthetic plan_date, report each with the SQL run and the result:
   - 1: warehouse-sourced Add New after push appears in packing queue bound FEFO, appears in field
     app with no manual flag.
   - 2: `add_m2m_transfer` two-row/one-transfer-id check.
   - 3: driver split into three rows, parent reduced, nothing new in packing queue (this is
     prd130_04's own fix, so run it for real this time, not just the synthetic trigger test).
   - 4: `add_intra_machine_move` + receive: pod_inventory shows correct shelf state (this is
     prd130_03's fix, run it for real via the actual RPC end to end, not the synthetic harness
     used to draft the migration).
   - 5: G-DISP-INVISIBLE, G-M2M-ORPHAN, G-SPLIT, G-RETURN-CREDIT all return 0.
   - 6: direct insert into `pod_inventory_edits` as field_staff fails.
4. Merge `prd130-dispatch-edit-paths` into `main`, push.

## Step 2: prd131_01

Apply `supabase/migrations/20260922160000_prd131_01_movement_kind.sql`. End with the standing
rolled-back smoke call this migration's own comments describe (already proven during drafting:
warehouse_fill 38368, warehouse_return 3289, legacy_noop 216, transfer_out 95, transfer_in 86,
intra_out/intra_in 0/0, unclassifiable 0). Confirm the live apply matches.

## Step 3: prd131_02, only if the gate holds

The push_plan_to_dispatch proof gate is already green (see pre-flight). Apply
`supabase/migrations/20260922163000_prd131_02_writers_set_kind.sql`. If for any reason the gate
is re-checked and is NOT green, stop here and say so; prd131_01 alone still goes live.

## Step 4: F7 and F10 scripts

1. Run `scripts/prd131_f7_repair_20260922.sql` (read-only, no gating dependency). Report the
   printed variance table as-is.
2. Run `scripts/prd131_f10_activia_repair_20260922.sql` (rewritten 2026-09-23; the pod_inventory
   restore is already done from earlier this session, this only supersedes the two disposition
   events properly and schedules the real 1+3 unit Remove for 2026-09-23). Requires prd131_02 to
   be live (step 3) for `add_dispatch_row` to set movement_kind. If step 3 was held, hold this
   script's Part 2 (the add_dispatch_row calls) and say so; Part 1 (supersession) has no such
   dependency and can still run.

## Step 5: guards

Apply `supabase/migrations/20260922180000_prd131_08_guards_kind_null_m2w.sql`. Then run:

```sql
SELECT check_name, severity, machine_name, detail
FROM check_machine_health_integrity()
WHERE check_name IN (
  'G-KIND-NULL','G-M2W','G-KIND-PACK','G-KIND-CREDIT','G-RETURN-STALE','G-RETURN-GAP',
  'G-EXPIRY-TAP-OFFSITE','G-M2M-ORPHAN','G-OVERLOAD'
)
ORDER BY check_name;
```

Expected, from testing today (re-verify live, do not assume):

- G-KIND-NULL: 0
- G-M2W: 0
- G-KIND-PACK: 0
- G-KIND-CREDIT: 1, real and old (NOVO-1023-0000-W0, transfer_out, dispatch_date 2026-06-23, a
  `B3 receive:` warehouse credit on a transfer leg). Not a bug from tonight. Report it, do not
  repair it as part of this batch.
- G-RETURN-STALE: 1 within the 14-day scope, real and current (WPP-1002-4300-O1 A12, Sunbites
  Olive And Oregano x2, driver confirmed 2026-09-14, still unapproved). Report it.
- G-RETURN-GAP: 0 (nothing populates receipt_gap_qty yet).
- G-EXPIRY-TAP-OFFSITE: should now be 0 if step 4's F10 script ran (it supersedes the two events
  this guard was finding). If step 4 was skipped or only partially run, this may still show 2.
- G-M2M-ORPHAN, G-OVERLOAD: already-existing guards, expect 0 (unchanged by tonight's work).

Paste the full result table in the report, whatever it actually shows. Do not force any number
to match this list if live data disagrees.

## Step 6: production deploy

Deploy the receipt card (`src/components/inventory/WarehouseConfirmationsPanel.tsx`) and the field
app button-text change (`src/app/(field)/field/dispatching/[machineId]/page.tsx`), both already
committed and pushed to `prd131-movement-kind` earlier this session. Safe with or without
prd131_02 live, since the receipt card calls the pre-existing `wm_confirm_line_split`. Merge
`prd131-movement-kind` into `main` (only the parts already safe to ship: the receipt card and
field app commits; prd131_03/F3 and anything gated on it stay on the branch), push, confirm the
Vercel deploy.

## Step 7: report and stop

State the actual Dubai time. Report each step's result. Do not proceed to F6/F8-remaining-stubs,
`wm_confirm_return` (section 4c), the field app Not-found/intra-pair work (section 4d), or the
`prd131-packing-screen` branch merge -- all explicitly deferred to a future session.
