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

Next: A2 (repair the real stuck transfer 91240fab-0c1e-4b96-853a-0b887e5a2c62).

## Open issues

- docs/prds/PRD-133-135-selection-strategist-learning.md needs to be authored from the /loop
  prompt's own Phase B/C text before B1 starts (not done yet).
- Scope of remaining work (A2 through A6, all of Phase B including a 24-day backtest, Phase C,
  Phase D report) is large. This is being worked in checkpointed steps across multiple turns, per
  the loop skill's dynamic mode, not attempted in one continuous pass.
