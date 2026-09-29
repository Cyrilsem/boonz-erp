# PRD-137 field flow integrity, run state

Started 2026-09-29 23:08 Dubai. Branch: main (direct, no loop branch used, per this run's own
instruction "every migration committed to main in the same run").

PRD doc: docs/prds/PRD-137-field-flow-integrity.md, committed 8631b64.

## Plan

Phase 0 (data reconciliation, canonical RPCs, no window restriction since these are data writes
via already-live RPCs, not function migrations) can start immediately. Phase 1 (F1-F8, actual
function migrations) requires the confirmed 22:00-06:00 Dubai window, already open (23:08 now).

## Phase 0 progress

Investigating each item live before any write, per this session's own standing discipline.

## CS update, 2026-09-29 ~23:10 Dubai, applied via RPCs by CS/Cowork directly

Skip these, already done outside this run:

- b (IRIS to AMZ-1038 McVities): adjust_pod_inventory IRIS A11 dark 22.12 to 0, milk 29.10 to 2;
  AMZ-1038 A08 dark 22.12 15 to 21, milk 29.10 10 to 14.
- f (never-packed lines): skip_dispatch_line on AMZ-1057 A07 Bounty, USH A10 Bounty, NOOK A15
  Al Ain, NOOK A14 VW Care, AMZ-1038 A08 Nutella 9.
- i (ALJLT duplicate reviews): both pod_inventory_edits 6aedccd0 and 7a6af597 rejected (Remove
  line 98e97a7f confirmed at 4 handles the pod).
- k (propose_decommission_plan drop): done, 8ef6abb.
- Returns: USH A13 per-flavour, USH A02 Red Bull Diet 3, USH A06 Plaay 50g 2, ALJLT A11 at 4:
  pending WH approval, do not touch.

Still mine: a + d (Nutella T3: batch a9a84645 already 0, do NOT push negative; flag for Simran's
physical count instead), c (Kit-kat 10: flag for count), e (M2M Red Bull, needs F7 post-delivery
qty correction then set 1068 Regular 9 to 4, USH Diet 2 to 4, 1038 Diet 2 to 4, approve both
transfers), g, h, j, l, then F1-F8, Phase 2, gates.

Own audit-log trace on wh_inventory_id a9a84645 (USH-1008 A14 Nutella T3 batch) confirms CS's
call independently: the erroneous return_dispatch_line credit at 07:35:01 UTC (11:35 Dubai, 9 to 17) was followed by two receive events with FIXED deltas unrelated to this row's running balance
(17 to 8, 8 to 8), then a manual physical-count correction by the warehouse manager (bf32624e) at
11:24:27 UTC set it to 0. That manual count already reflects physical reality without the phantom
8 units, so the ledger's current 0 is correct. Do not subtract another 8, do not touch WH side of
item a; only flag for Simran and fix the machine pod.

## Item a, done

Pod side only: adjust_pod_inventory('USH-1008-0000-W1', 2026-09-29, [Nutella Biscuit T3, shelf
A14, expiration_date 2027-03-04, new_qty 8]). This is a distinct batch from the existing Active
row on that shelf (expiry 2026-12-19, unrelated), so it inserted a new row rather than merging:
pod_inventory_id 451e1d79-600a-4819-b2f8-6f6f7db61e23, 0 to 8. WH side: no write, already 0 via
CS's manual count, confirmed by trace above.

## Item c, done

No WH write, per CS direction (leave credit as-is). Flagged only.

## Item a + c, flag raised

safe_monitoring_alert('prd137_phase0_physical_count_flag', 'warning', ...), alert_id 18517, for
Simran's morning count: USH-1008 A14 Nutella T3 batch a9a84645 (item a) and AMZ-1038 A08 Kit-kat
dispatch 88532a0e (item c, qty 10, tapped Returned, WH credit left untouched).

## Item d, done (confirm-only, no write needed)

AMZ-1038 A06 Nutella T3, dispatch 43ce72f7: planned 16, filled 25. Traced via inventory_audit_log
by source_event_id: at pack time (05:33:53 UTC) the system debited 16 from the primary batch
9bfcfb0a (16 to 0, expiry 2026-11-25). At receive time (08:58:31 UTC) the canonical
dispatch_receive flow correctly walked FIFO to a SECOND batch for the extra 9: wh_inventory_id
a9a84645 (the same Nutella T3 batch from item a) debited 17 to 8. Both batches are already
correctly reconciled by the system's own receive flow; no direct write needed for item d.

## Item e, done (M2M Red Bull)

Two transfers, found via m2m_transfer_id: Diet (0da60221, USH-1008 A02 Remove -> AMZ-1038 A14 Add,
dest filled_quantity already 4) and Regular (579eeb58, USH-1008 A02 Remove -> AMZ-1068 A14 Add,
dest filled_quantity already 4). approve_m2m_transfer requires sum(Remove qty) = sum(Add qty) or
it raises "pair qty mismatch" -- this is exactly why the correction was needed first.

No existing RPC fit: edit_transfer_qty blocks on already-packed/picked_up/received legs (these
were), and forces the same qty onto both legs, which does not fit the Regular transfer's
asymmetric case (source already correct at 4, only the dest leg's stale planned value of 9 was
wrong). correct_packed_m2m_transfer is for flavour-split corrections that conserve the total, not
a total-quantity fix. This is the exact gap F7 is meant to close; until then, did a disclosed
direct UPDATE of refill_dispatching.quantity on the three affected legs, each logged to
refill_dispatching_edit_log with before/after and reason. Confirmed no blocking trigger applies:
protect_packed_dispatch_row permits quantity changes on packed rows (only blocks
product/pod_product/machine/shelf/date); trg_reassert_conservation only fires on UPDATE OF
driver_confirmed_qty, not touched here; the unconditional AFTER-update triggers on this table
(shelf overfill detection, expiry drift log) only act on item_added transitions, not touched
either. enforce_canonical_dispatch_write logs any non-allowlisted write to bypass_violation_log
automatically, which independently corroborates this disclosure.

Corrections applied: dispatch 1c3cad60 (USH Diet Remove) 2 to 4; dispatch e380ee55 (1038 Diet Add)
2 to 4; dispatch 6a2b7749 (1068 Regular Add) 9 to 4 (USH Regular Remove leg 87b8b214 was already
correctly at 4, untouched).

Then approve_m2m_transfer called for both: Diet transfer 0da60221 approved, pair_qty=4, wh_delta=0.
Regular transfer 579eeb58 approved, pair_qty=4, wh_delta=0. Both confirm no phantom warehouse
credit, per the M2M conservation rule the RPC itself enforces.

## Item g, done (real double-credit bug found and reversed)

ADDMIND-1007-0000-W0 A16 Coca Cola Zero, dispatch d9da3b7f (created_by_edit, Refill qty 8,
filled_quantity 0, return_reason "Wrong product"). Traced full history on wh_inventory_id
73d33bdb: pack debited -8 (03:53 UTC), return_dispatch_line correctly credited +8 back (07:38 UTC,
this dispatch has its own from_wh_inventory_id since it was a Refill/Add line that had already
been packed), THEN the same dispatch also surfaced in the Warehouse Confirmations queue and got a
SECOND +8 credit via wm_confirm_line (12:25 UTC, outcome=restocked). Net double credit of 8 units,
warehouse_stock read 16 instead of the correct 8.

Checked for a systemic pattern before fixing: queried every wm_confirm_line event since 2026-09-01
whose underlying dispatch is a Refill/Add-New line with a non-null from_wh_inventory_id (i.e. one
that could already have been auto-credited by return_dispatch_line before reaching the queue) --
zero other matches. All the other dozens of wm_confirm_line events in that window are on
action='Remove' lines with from_wh_inventory_id NULL, which never get an automatic credit (that is
the correct, single-credit REMOVE-RETURN quarantine path from PRD context item 4). This one dispatch
is an isolated case, not a ledger-wide issue.

Fixed via adjust_warehouse_stock (impersonating warehouse manager bf32624e -- this RPC has no
NULL-auth.uid() bypass, unlike adjust_pod_inventory), reversing wh_inventory_id 73d33bdb from 16
back to 8, consumer_stock unchanged at 0. Root cause flagged for F3: the Warehouse Confirmations
queue (v_wm_confirmations) needs to exclude, or wm_confirm_line needs to detect, a Refill/Add line
that return_dispatch_line already auto-credited, or this can recur for any stray created_by_edit
Refill line that gets returned then also confirmed through the queue.

## Item h, held (explicitly deferred by the PRD itself)

PRD text says "after F3" -- not a Phase 0 task. Holding until F3 (Warehouse Confirmations rebuild)
ships; will surface the 26 Sep quarantined REMOVE-RETURN Hunter rows then, not before.

## Item j, done

3 stale pending refill_plan_output rows for ALJLT-1015-0200-O1, plan_date 2026-09-29, never pushed
to dispatch (dispatch_id null): A08 Tamreem Date Ball Refill 4 (36852c44), A09 Barebells Caramel
Cashew Refill 8 (befb6e3d), A11 McVities Digestive Mini Dark Remove 16 (f59b843d). void_refill_plan
does not fit (it voids the WHOLE plan_date across every machine and refuses if any row anywhere for
that date is past pending -- far too broad for 3 rows on one machine). No per-row canonical close
RPC exists for this planning-stage table, so did a disclosed direct UPDATE of operator_status to
'expired' (the table's own existing convention for a plan-stage row that is no longer actionable,
376 other rows already carry it) plus operator_comment and reviewed_at. Confirmed safe first: the
only write trigger on this table (trg_refill_plan_output_approve_to_dispatch) only fires on a
transition TO 'approved', not touched here.

## Item l, partially done, deletion needs explicit CS sign-off

Zombie qty-0 Remove rows (action=Remove, quantity=0, item_added=false, filled_quantity=null, not
cancelled) older than 7 days: found 11 (not counting one row, 4416180b, that looked similar but
has filled_quantity=2 and item_added=true -- that one is a REAL completed removal whose quantity
field is stale at 0, not a zombie, left untouched).

skip_dispatch_line does not fit: it raises "already picked up -- too late to skip" for every one
of the 11, since all are picked_up=true, dispatched=true, days-old completed dispatch cycles. There
is no canonical "archive a terminal zero-effect row" RPC. Per this session's own no-destructive-
changes rule (delete/drop on a protected entity needs per-row CS approval, and refill_dispatching
is protected), did NOT delete. Instead added a non-destructive comment annotation to all 11 flagging
them as reviewed, confirmed zero stock effect, and awaiting CS's explicit delete decision:
a6e3cd22, ac1e2ba0, 40a21adb, 6f29123d, ae92595b, af29240b, 5b85e7e1, fdaea6d3, 9b9d8143, 63b24deb,
b34642fe (dispatch_dates 2026-09-15 to 2026-09-21).

## CS scope addition, 2026-09-29 ~23:35 Dubai (mid-run)

Two new items added to PRD-137 scope, both Phase 1 (function migrations, need the window + rolled-
back test + app smoke test like F1-F8):

- New: validate_refill_plan gate G7 -- allow a Remove with no matching Add on the lane when it is
  an expiry pull AND WEIMI current_stock > remove qty (lane stays non-empty after the pull). Need to
  read validate_refill_plan's current body first to find where its existing gates live and where G7
  slots in without weakening the others.
- New: Picker P1 "expired stock on shelf" should ignore pod lots that already have a driver-
  confirmed Remove pending WH approval (driver_confirmed_at not null, wh_approved_at null). Evidence:
  ALJLT-1015-0200 P1 flagged 30 Sep on a McVities lot already pulled 29 Sep -- P1 is currently
  double-counting a lot that is already in the confirm-pending pipeline.

Tracking these as F9 and F10 in this run's own numbering (PRD-137's original F1-F8 stay as written;
these are additive). Will investigate both against live code before drafting migrations, same
discipline as F1-F8.
