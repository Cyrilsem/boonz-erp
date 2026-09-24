# Loop state: Selection v2 + refill engine P0 fixes

Branch: loop/selection-v2-2026-09-25 (from main)
Started: 2026-09-25 00:48 Dubai
Gated window check at start: `now() at time zone 'Asia/Dubai'` = 2026-09-25 00:48:52. Inside the
22:00-06:00 window. Target: Phase A done by 05:45.

## Progress log

### 2026-09-25 00:48 Dubai, setup

- Created branch loop/selection-v2-2026-09-25 from origin/main.
- Confirmed gated window is open (00:48 Dubai, inside 22:00-06:00).
- docs/prds/PRD-133-135-selection-strategist-learning.md: not found in repo, not found in the
  BOONZ BRAIN folder on disk. No tool access to a Claude.ai project doc store from this session.
  Falling back to "recreate from this prompt" as explicitly permitted. Will write it from the
  /loop prompt's own Phase B/C specification before starting B1.

### 2026-09-25 01:06 Dubai, A1 done, applied

Migration: supabase/migrations/20260925010000_loopv2_a1_m2m_cancel.sql
Rollback: docs/rollbacks/20260925010000_loopv2_a1_rollback.sql
Commit: d720c5f on loop/selection-v2-2026-09-25, pushed.

Root cause confirmed live before writing anything: push_plan_to_dispatch
(v19_prd12x_j4_source_warehouse_id_fix) set (packed, picked_up, dispatched, returned, item_added)
= (true, true, true, false, false) on an M2M transfer's source Remove leg at push. The destination
Add New leg already inserted with picked_up=false. skip_dispatch_line refuses any row with
picked_up=true, so a transfer could never be cancelled between push and the driver starting it.

Fix 1: source leg's picked_up literal changed true to false. Nothing else in that INSERT changed.

Fix 2: new RPC cancel_m2m_transfer(p_transfer_id, p_reason, p_convert_source_to_return default
true, p_dry_run default true). Refuses if either leg has driver_confirmed_at, driver_outcome,
returned, or filled_quantity>0. Zeroes and skips both legs (same column set skip_dispatch_line
uses, plus quantity=0), logs one edit_log row per leg, and when convert=true inserts a plain
Remove to the source machine's own primary_warehouse_id via add_dispatch_row.

Three real gaps found and fixed while smoke testing in rolled-back transactions, none assumed:

1. refill_dispatching_edit_log.edited_by_role is NOT NULL. Fixed with COALESCE(v_role,'system')
   in cancel_m2m_transfer's own writes.
2. refill_dispatching_edit_log_edit_kind_check and the paired
   refill_dispatching_edit_log_state_coherence constraint are both closed enumerations with no
   value for cancelling a whole transfer. Widened both, forward only, new value
   'cancel_m2m_transfer', same shape as qty/shelf/product/source/decline_swap (before_state and
   after_state both required).
3. add_dispatch_row's own edit_log insert passes p_edit_role straight through with no COALESCE,
   which fails the same NOT NULL constraint when called with no real session role. Worked around
   locally by passing COALESCE(v_role,'system') from cancel_m2m_transfer's own call.
   add_dispatch_row itself was not touched, out of A1's surgical scope.

Smoke calls, all rolled back before the real apply:

1. push_plan_to_dispatch M2M pair test (WAVEMAKER-1006-4100-O1 A01 to AMZ-1046-2406-O1 A13, Coca
   Cola Zero, synthetic plan_date 2031-06-01): both legs packed=true, picked_up=false. Green.
2. cancel_m2m_transfer happy path (synthetic pair, dispatch_date 2031-06-02, convert=true): both
   legs quantity=0/skipped=true/include=false; new Remove row created with source_kind='wh',
   source_warehouse_id=4bebef68-9e36-4a5c-9c2c-142f8dbdae85 (WAVEMAKER's own primary_warehouse_id,
   which is WH_CENTRAL). Green.
3. Guard test: a transfer with driver_confirmed_at set was correctly refused with an exception.
   Green.

Applied to prod via apply_migration at 01:06 Dubai (confirmed inside window immediately before
apply). Verified live: cancel_m2m_transfer exists with exactly one overload; the edit_kind check
constraint now includes 'cancel_m2m_transfer'.

### 2026-09-25 01:17 to 01:20 Dubai, A2 done

Migration: supabase/migrations/20260925011500_loopv2_a2_fix_cancel_dest_lookup.sql
Rollback: docs/rollbacks/20260925011500_loopv2_a2_rollback.sql
Commit: 404d0c9 on loop/selection-v2-2026-09-25, pushed.

Checked transfer 91240fab-0c1e-4b96-853a-0b887e5a2c62 first, before touching anything. Source leg
(VML-1004-0500-O1 A03, Remove, Red Bull, qty 7, dispatch_id b9cc6aed...) had no driver activity
(driver_confirmed_at, driver_outcome, returned, filled_quantity all clear) but was packed=true,
picked_up=true, dispatched=true from before A1's fix, exactly the scenario A1 exists to prevent
going forward. Dest leg (AMZ-1029-3003-O1 A14, dispatch_id 917a479a...) was already skipped=true,
include=false, as A2's own text said, but not yet zeroed (quantity still 7) and still carrying
action='Refill', not 'Add New'.

Real bug found before running anything for real: cancel_m2m_transfer's destination lookup filtered
on action IN ('Add New','Add'), which does not match this real leg's action='Refill'.
push_plan_to_dispatch's v_action mapping preserves whatever the plan's own action label was onto
the M2M destination leg, so 'Refill' is a legitimate destination action, not just 'Add New'. Fixed
by looking up the partner via m2m_partner_id instead (migration
20260925011500_loopv2_a2_fix_cancel_dest_lookup.sql), tested in a rolled-back dry run against this
exact real transfer first (green: both legs resolved correctly, dest_already_skipped=true, no
driver-activity block), then applied to prod at 01:17 Dubai (confirmed inside window).

Ran cancel_m2m_transfer live: dry run again (green, same result), then the real call
(convert_source_to_return=true, reason "CS 24 Sep: Red Bull 7 back to WH, AMZ-1029 355ML lane
being depleted"). Result: status=cancelled, new Remove dispatch_id 61310768-b5ef-4d70-bff3-143a2ebc7301
created. Read back and verified: source leg quantity=0/skipped=true/include=false; dest leg
quantity=0/skipped=true/include=false; new Remove row quantity=7/skipped=false/include=true,
source_kind=wh, source_warehouse_id=4bebef68-9e36-4a5c-9c2c-142f8dbdae85 (VML-1004's own
primary_warehouse_id, WH_CENTRAL), m2m_transfer_id=NULL (standalone, not part of any transfer).
Mutation reason set: "cancel_m2m_transfer 91240fab-0c1e-4b96-853a-0b887e5a2c62 by=system: CS 24
Sep: Red Bull 7 back to WH, AMZ-1029 355ML lane being depleted" plus add_dispatch_row's own
"cancel_m2m_transfer ... converted to warehouse return: ..." reason on the new row.

### 2026-09-25 01:20 to 01:26 Dubai, A3 done

Migration: supabase/migrations/20260925013000_loopv2_a3_g3_coverage_fix.sql
Rollback: docs/rollbacks/20260925013000_loopv2_a3_rollback.sql
Commit: ab6372b on loop/selection-v2-2026-09-25, pushed.

Root cause confirmed live: the "G3" check is in validate_refill_plan (write_refill_plan's own
final call), not preflight_refill_plan (a separate function using INV-01..INV-12 naming with no
G-numbered checks). validate_refill_plan's lines CTE branches on p_source ('dispatch' XOR
'plan_output'); write_refill_plan always calls it with p_source='plan_output', so lines only ever
sees refill_plan_output rows with operator_status='pending'. Any lane already covered by an
approved plan_output line, or by anything in refill_dispatching at all (that whole branch requires
p_source='dispatch'), is invisible to G3's lane.n_lines count.

Confirmed on the named evidence: AMZ-1029-3003-O1 A10 (Hunter Ridge, pod_product_id
51e4600f-2c15-428b-92ef-85fdc783c3af) is genuinely empty in v_live_shelf_stock (0/8) but has three
refill_plan_output rows for plan_date 2026-09-25, action=Refill, operator_status=approved,
dispatched=true, quantities 1+4+3=8. None visible to G3's old logic.

Fixed G3 only: added two NOT EXISTS checks (approved plan_output coverage, live dispatch
coverage) for the exact plan_date+machine+shelf. G5, G7, G8, G10 untouched.

Verified without touching plan_date 2026-09-25 with any write, per the hard rule: ran the two new
NOT EXISTS conditions as plain read-only SELECTs against the real AMZ-1029 A10 data first
(covered_by_approved_plan_output=true, covered_by_dispatch=true), then ran the full modified
function in a rolled-back transaction against 2026-09-24 (AMZ-1029-3003-O1) and 2026-09-23
(fleet-wide, p_source='dispatch'): no errors, 13 real G8 violations still correctly surfaced for
2026-09-23 (e.g. Red Bull need 15 free 0), proving the other G-checks are unaffected. Applied to
prod at 01:26 Dubai (confirmed inside window), verified live.

Next: A4 (G4 M2M destination lot binding must match flavour).

## Open issues

- docs/prds/PRD-133-135-selection-strategist-learning.md needs to be authored from the /loop
  prompt's own Phase B/C text before B1 starts (not done yet).
- Scope of remaining work (A4 through A6, all of Phase B including a 24-day backtest, Phase C,
  Phase D report) is large. This is being worked in checkpointed steps across multiple turns, per
  the loop skill's dynamic mode, not attempted in one continuous pass.
