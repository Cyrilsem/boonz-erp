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

### 2026-09-25 01:34 to 01:52 Dubai, A4 done, applied

Migration: supabase/migrations/20260925020000_loopv2_a4_m2m_lot_flavour_match.sql
Rollback: docs/rollbacks/20260925020000_loopv2_a4_rollback.sql
Commit: b225b86 on loop/selection-v2-2026-09-25, pushed.

Root cause confirmed live before writing anything: push_plan_to_dispatch's M2M source (Remove) leg
lot lookup and add_m2m_transfer's Remove leg lot lookup both select the earliest-expiry Active
pod_inventory row on the source shelf via v_pod_inventory_latest, filtered only on machine_id,
shelf_id, status, current_stock, with no boonz_product_id filter even though the view carries that
column.

Confirmed on the named evidence: ADDMIND-1007 A16 (machine_id 60a64b01-483a-48c9-a842-
ca09468452a6, shelf_id fa98304f-c0da-4a03-abdb-b1418672332c) carries three Active lots on one
shelf: Zero peach (expires 2027-01-10), Zero Lemon (expiry NULL), Antioxidant (expires
2026-09-27). The unfiltered query always returns Antioxidant regardless of which product is being
moved. Read-only confirmation before any code change: unfiltered query returned Antioxidant
2026-09-27; filtered to Zero peach's boonz_product_id returned 2027-01-10; filtered to Zero
Lemon's returned NULL; filtered to a nonexistent product returned no row (correct NULL fallback).

Fix: added AND pil.boonz_product_id = <the product being transferred> to both lookups. Left the
equivalent shelf-only lookup for the plain (non-M2M) Remove/Machine To Warehouse leg further down
in push_plan_to_dispatch untouched, out of A4's named scope (listed below as an open issue).

Incidental fix in the same migration, same function: add_m2m_transfer hardcoded edited_by_role to
a literal NULL in its own edit_log insert (not even COALESCE(v_role,...)), which violates
refill_dispatching_edit_log's NOT NULL constraint on every call, authenticated or not. Found while
smoke testing (23502 on first attempt, with a real auth.uid() NULL test caller). Fixed with the
same COALESCE(v_role,'system') fallback A1 established for cancel_m2m_transfer, since this
function's body was already being replaced for A4 and the bug blocks any real use of it.

Smoke calls, both rolled back before the real apply:

1. add_m2m_transfer, real ADDMIND-1007 A16 -> MC-2004-0100-O1 B16, Zero peach qty 1: after the fix,
   the Remove leg's expiry_date=2027-01-10 and pod_lot_id=4fecca07-6577-4563-9d78-de9e99bcd2b6
   (Zero peach's own lot), not Antioxidant's. Before the incidental fix this call failed with
   23502 on edited_by_role; after, it succeeded end to end. Green.
2. push_plan_to_dispatch, full M2M pairing path with synthetic approved refill_plan_output rows
   (ADDMIND-1007 A16 Remove -> MC-2004-0100-O1 B16 Add New, Zero peach qty 1, plan_date
   2031-06-06): resulting Remove leg expiry_date=2027-01-10, pod_lot_id=4fecca07-...; the paired
   destination Add New leg correctly inherited expiry_date=2027-01-10 via the grouped insert, not
   Antioxidant's 2026-09-27. Green.

Applied to prod via apply_migration at 01:52 Dubai (confirmed inside window immediately before
apply, dubai_now 01:49:48). Verified live: push_plan_to_dispatch's body now contains
rpc_version='v21_loopv2_a4_m2m_lot_flavour_match'.

### 2026-09-25 01:56 to 02:04 Dubai, A5 done, applied

Migration: supabase/migrations/20260925030000_loopv2_a5_m2w_suppress_qty_zero.sql
Rollback: docs/rollbacks/20260925030000_loopv2_a5_rollback.sql
Commit: 9aa0a58 on loop/selection-v2-2026-09-25, pushed.

Root cause confirmed live before writing anything: engine_finalize_pod's auto-suppress branch
(fires when a draft REMOVE/M2W line has no paired ADD_NEW/REFILL replacement on the same shelf and
no approved decom tag) sets status='superseded' and stamps reasoning.auto_suppressed, but the
UPDATE's SET list never touches qty. Confirmed on the named evidence: VML-1004-0500-O1 A03, Red
Bull, plan_date 2026-09-25, action M2W, qty 12, status superseded, reasoning.auto_suppressed = 'no
replacement for shelf', still reading qty 12.

Fix: added qty = 0 to the same UPDATE's SET list, plus reasoning.auto_suppressed_prior_qty to keep
the original quantity visible for audit, and bumped auto_suppressed_by /engine_version tags
(engine_finalize_pod_v14_loopv2_a5_qty_zero / v15_2_loopv2_a5_m2w_qty_zero) so this version is
distinguishable. No other logic in the function changed. Plan_date 2026-09-25's own already-
superseded VML-1004 A03 row was NOT touched, per the hard rule; this is forward-only.

Smoke call, rolled back before the real apply: seeded a pod_swaps M2W row (ADDMIND-1007 A16,
qty 9, no ADD_NEW/REFILL replacement on that shelf in the same run) for synthetic plan_date
2031-06-08, then ran the fixed engine_finalize_pod. Result row: action=M2W, qty=0 (was 9),
status=superseded, reasoning.auto_suppressed='no replacement for shelf',
auto_suppressed_by='engine_finalize_pod_v14_loopv2_a5_qty_zero',
auto_suppressed_prior_qty='9'. Green. (First attempt seeded the row directly into pod_refill_plan
as 'draft', which the function's own leading UPDATE, wiping all draft rows for the plan_date before
regenerating, immediately flipped to superseded with no reasoning tag before the orphan-detection
logic ever ran; corrected by seeding via pod_swaps instead so the row is freshly generated as draft
inside the same call, which is how any real run would produce it.)

Applied to prod via apply_migration at 02:04 Dubai (confirmed inside window, dubai_now 02:04:28).
Verified live: engine_finalize_pod(date, uuid[]) now contains engine_version
'v15_2_loopv2_a5_m2w_qty_zero'.

### 2026-09-25 02:09 to 02:14 Dubai, A6 done, applied (data, not gated)

Migration: supabase/migrations/20260925040000_loopv2_a6_red_bull_355ml_alias.sql
Commit: d01f0c2 on loop/selection-v2-2026-09-25, pushed. No rollback file: a single-row reference
table INSERT with ON CONFLICT DO NOTHING, not a function change; rollback is DELETE FROM
weimi_product_alias WHERE weimi_name='Red bull 355ML' AND pod_product_id='a602c923-c4c0-4ecc-b5f7-
3c13a1960beb' if ever needed.

Investigated the task's own premise against live data before creating anything, per this loop's
standing discipline. Findings, in order:

1. A generic pod product "Red Bull" (a602c923-c4c0-4ecc-b5f7-3c13a1960beb) already exists.
2. boonz_products already has "Red Bull - 355ML" (e21bae75-cdeb-42a9-b6ad-df8f5d4166dc) with an
   Active, machine-scoped product_mapping to that same pod product, for machine_id f1a528fb-15e8-
   4f20-b4e2-ebb2e6852198 (AMZ-1029-3003-O1), exactly the machine named in the sku_intents evidence.
3. pod_inventory history for AMZ-1029-3003-O1 A14 shows three different boonz_product variants
   (Red Bull Diet, Regular, 355ML) have occupied that lane over time, all correctly sharing the
   one generic "Red Bull" pod product. That is the intended model: pod identity is the physical
   can, boonz_product_id is the SKU/flavour sold from it.
4. v_shelf_slot_identity already resolves this shelf's raw WEIMI string ("Red bull 355ML") to
   pod_product_id a602c923 via match_method='conventions' (a fuzzy matcher), not 'unmatched'.

Conclusion: creating a new, separate pod product literally named "Red bull 355ML" would have
fragmented an identity that is already correct and already shared correctly across three real SKU
variants. Did NOT create a new pod product and did NOT change product_mapping (the existing Active
mapping is already correct). Instead added one explicit weimi_product_alias row (Red bull 355ML ->
a602c923) so this shelf's resolution stops depending on the fuzzy conventions matcher. Verified
live: row present with the expected pod_product_id.

WEIMI unmatched sweep (v_shelf_slot_identity.match_method='unmatched'), fixed only the Red Bull
case above; the rest left unfixed per "fix only exact, unambiguous ones":

- "C4 Energy Drink" (LVLUP-1018-0000-G0 A05 stock 2, LVLUP-1048-0000-P0 A09 stock 4): no C4 pod
  product exists at all. LVLUP machines are excluded from planning entirely per this loop's own
  hard rules, so even a correct mapping would never be used by a plan. Not fixed, not unambiguous.
- "Plaay Cylinder" (WH1-2002-0000-W0, shelves B05/B06/B07, stock 2 to 4): several existing Plaay
  pod products (Truffle 2pcs, Tablet Chocolate, Tablet Chocolate 35g) but none named or shaped
  like a "Cylinder" format. Ambiguous, not fixed.
- "Product for testing only" (WH1-2002-0000-W0, shelves A12/A14, stock 0): a test fixture, not a
  real product. Correctly left unmapped.

Next: Phase B (B1 picker_config switch), starting with authoring
docs/prds/PRD-133-135-selection-strategist-learning.md.

## Open issues

- docs/prds/PRD-133-135-selection-strategist-learning.md needs to be authored from the /loop
  prompt's own Phase B/C text before B1 starts (not done yet).
- The plain (non-M2M) Remove/Machine To Warehouse leg lot lookup in push_plan_to_dispatch has the
  same missing-boonz_product_id-filter shape as the bug A4 fixed, but is a separate code path
  outside A4's named scope (G4 names M2M destination binding specifically). Left unfixed; worth a
  follow-up PRD item if a similar wrong-flavour expiry is ever reported on a plain Remove/M2W leg.
- Scope of remaining work (A5 through A6, all of Phase B including a 24-day backtest, Phase C,
  Phase D report) is large. This is being worked in checkpointed steps across multiple turns, per
  the loop skill's dynamic mode, not attempted in one continuous pass.
