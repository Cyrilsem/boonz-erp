# PRD-116 item B follow-up — same-machine transfers are unclassifiable and, for driver splits, unapprovable

**Date:** 24 Aug 2026 · **Author:** Claude for CS · **Status:** DESIGN ONLY — nothing applied, needs Cody review before any migration

**Confirmed against live rows 2026-08-24.** This is a follow-up to the PRD-116b re-verification finding (see `project_prd116_refill_edge_case_hardening.md`): `is_internal_move_dispatch`'s branch order makes same-machine "m2m" tags unreachable. CS confirmed the bug and identified two more consequences the initial finding missed: PRD-116b's own inheritance fix makes the driver-split case _worse_, not just unfixed, and a second writer (`wh_approve_remove_receipt`) has the identical bug pattern independently, so reordering the classifier alone doesn't fully close this. This doc specs all of it.

## Root cause, traced to the write site

`add_dispatch_row` sets `is_m2m` unconditionally from the requested source kind, with no same-machine check at all:

```sql
-- current, live:
p_source_kind, p_source_warehouse_id, p_source_machine_id,
(p_source_kind IN ('m2m','truck_transfer')), true,   -- is_m2m, created_by_edit
```

There is no comparison of `p_source_machine_id` to `p_machine_id` (the destination) anywhere in the function. A same-machine shelf-to-shelf move requested with `p_source_kind='m2m'` and `p_source_machine_id = p_machine_id` gets `is_m2m=true` — indistinguishable, at the row level, from a genuine cross-machine transfer. Everything downstream inherits or reacts to that wrong tag.

## Three places the wrong tag causes real damage

**1. `is_internal_move_dispatch` (the classifier) — confirmed live, 72/72 real same-machine `source_kind='m2m'` rows misclassified.**

```sql
WHEN COALESCE(rd.is_m2m, false) THEN false                                    -- fires first
WHEN rd.source_kind = 'm2m' AND rd.source_machine_id = rd.machine_id THEN true -- dead code today
```

**2. `wh_approve_remove_receipt` and `wh_approve_remove_receipt_multivariant` — same bug pattern, independently, confirmed by reading both live bodies.** Both check `is_m2m` and raise _before_ ever calling `is_internal_move_dispatch`:

```sql
IF COALESCE(v_dispatch.is_m2m, false) THEN
  RAISE EXCEPTION '... approve via approve_m2m_transfer(%) ...';
END IF;
-- PRD-113 hard guard: never reached for a same-machine "m2m" row
IF COALESCE(public.is_internal_move_dispatch(p_dispatch_id), false) THEN
  RAISE EXCEPTION '... is an INTERNAL MOVE ...';
END IF;
```

**This means reordering the classifier's branches is not sufficient.** Even a perfectly-fixed `is_internal_move_dispatch` never gets called here for a same-machine row, because the `is_m2m` check above it already raised. This function needs its own fix regardless of what happens to the classifier. (`approve_stuck_remove` does NOT have this pattern — it only calls the classifier, no separate `is_m2m` gate — so it's affected by root cause #1 only, not this one.)

**3. PRD-116b's inheritance makes driver splits _worse_, and can produce an unapprovable row.** `insert_driver_remove_line` (the PRD-116b fix, live) has a child inherit `COALESCE(v_parent.is_m2m, false)` from the parent. Before PRD-116b, a split child had `source_kind='unknown'`, `is_m2m=false` — wrong, but it fell through the classifier's CASE to the PRD-113b fallback branch (the "MC-2004 shape" `EXISTS` check for a paired Add leg on another shelf), which had a _chance_ of correctly recognizing it as an internal move. After PRD-116b, the child correctly inherits `is_m2m=true` from a mistagged same-machine parent — and now hits branch 1 of the classifier (`WHEN COALESCE(rd.is_m2m,false) THEN false`) unconditionally, **never reaching the fallback that used to have a chance of catching it.** PRD-116b is doing exactly what it was speced to do; the thing it correctly propagates is itself wrong.

Worse: I checked `insert_driver_remove_line`'s INSERT column list (live) — it does not set `m2m_transfer_id` (not in its column list at all, so it stays `NULL`). Trace what that means for a same-machine driver-split child that inherited `is_m2m=true`:

- `wh_approve_remove_receipt` / `_multivariant` — refuses, tells the operator to use `approve_m2m_transfer`.
- `approve_m2m_transfer` — refuses (`no is_m2m legs for transfer %`) because `m2m_transfer_id` is `NULL`; there's nothing to pair against.
- `is_internal_move_dispatch` — returns `false`, so `clear_internal_move_flag`'s stated precondition ("this really is a warehouse return") doesn't obviously apply either, and nothing in the approval surface currently exposes a "this is actually an internal move, just tagged wrong" escape hatch that bypasses the `is_m2m` gate.

**A same-machine driver-split child can currently end up with no RPC-driven approval path at all.** This is a stronger claim than "misclassified" — it's a possible dead-end row, and worth prioritizing over the capacity/batch items in `PRD-116-phase2-capacity-and-batch.md`.

## Proposed fix (three coordinated changes, defense in depth — not just a reorder)

**B1 — fix the write site, `add_dispatch_row`.** Only set `is_m2m` true when the source is genuinely a different machine:

```sql
(p_source_kind = 'truck_transfer' OR (p_source_kind = 'm2m' AND p_source_machine_id IS DISTINCT FROM p_machine_id))
```

This is the forward-only, root-cause fix. It also fixes PRD-116b's inheritance _for free_, going forward — a parent created correctly with `is_m2m=false`/`source_kind='m2m'`/`source_machine_id=own machine` produces a child that inherits the same correct tags, no change needed in `insert_driver_remove_line` itself.

**B2 — fix the classifier regardless, `is_internal_move_dispatch`.** Don't rely solely on writers getting `is_m2m` right forever; `source_machine_id = machine_id` is unambiguous ground truth and should win even over a wrongly-set `is_m2m`:

```sql
WHEN rd.source_kind = 'm2m' AND rd.source_machine_id = rd.machine_id THEN true   -- moved up, ground truth first
WHEN COALESCE(rd.is_m2m, false) THEN false
```

This also makes B1 non-load-bearing for correctness (belt and suspenders) — if a future writer ever reintroduces the same mistake, the classifier still gets it right.

**B3 — fix `wh_approve_remove_receipt` and `wh_approve_remove_receipt_multivariant`, reorder their two guards.** Check `is_internal_move_dispatch` _before_ the `is_m2m` raise, not after — once B2 lands, the classifier is the authoritative same-machine-aware check and should get first refusal:

```sql
-- PRD-113 hard guard, now FIRST: an in-machine move must never be credited to the warehouse.
IF COALESCE(public.is_internal_move_dispatch(p_dispatch_id), false) THEN
  RAISE EXCEPTION '... is an INTERNAL MOVE ...';
END IF;
-- M2M hard guard, now SECOND: only reached for a genuine cross-machine transfer.
IF COALESCE(v_dispatch.is_m2m, false) THEN
  RAISE EXCEPTION '... approve via approve_m2m_transfer(%) ...';
END IF;
```

B2 and B3 together close the dead-end case even for historical mistagged rows (B1 alone can't, since it only affects new writes).

**B1+B2+B3 together, not B2 alone:** B2 fixes the classifier's own logic; B3 is required because two other writers independently gate on `is_m2m` before ever calling the classifier, so B2 alone is invisible to them. B1 is required because it's the only piece that stops new rows from being mistagged in the first place — without it, every future same-machine transfer keeps needing B2/B3 to bail it out.

## Historical data — a fourth, optional piece: backfill

72 real rows today have `source_kind='m2m'`, `source_machine_id=machine_id`, `is_m2m=true` — mistagged by the root cause. The criterion for identifying them is exact and safe (`source_kind='m2m' AND source_machine_id=machine_id`, unambiguous by construction), so a backfill `UPDATE refill_dispatching SET is_m2m=false WHERE source_kind='m2m' AND source_machine_id=machine_id AND is_m2m` is _technically_ clean. Whether to run it is a separate call from B1-B3 (which fix classification going forward regardless of the stored `is_m2m` value once B2/B3 land) — flagging it as available, not proposing to run it. Any already-`wh_approved_at`-settled row must stay untouched either way (append-only posture); this would only ever touch open/unapproved rows.

## For Cody

- Does reordering two `RAISE EXCEPTION` guards in `wh_approve_remove_receipt(_multivariant)` count as a body change needing the same md5-guard + verbatim-reproduce discipline as any other writer patch? (Assume yes, flagging for confirmation.)
- Is there a reason `insert_driver_remove_line` deliberately omits `m2m_transfer_id` on children (e.g. children are never meant to be part of a paired transfer even when inheriting `is_m2m=true`), or is that itself a gap once B1 stops making the situation arise? If B1+B2+B3 land, this stops mattering for the same-machine case — but a genuinely cross-machine parent split via `insert_driver_remove_line` today would have the identical `m2m_transfer_id=NULL` problem for ITS children, which B1-B3 do not address. Worth its own look, out of scope here.
- Confirm B2's branch reorder doesn't change behavior for any row currently relying on the _old_ order in a way that's load-bearing elsewhere (a search of every `is_internal_move_dispatch(` call site, not just the ones this doc found, before applying).

## Rollout / rollback

All three (B1-B3) are `CREATE OR REPLACE FUNCTION` with the standard md5-guard-and-verbatim-reproduce pattern used for A/B/C tonight — no schema change, no data mutation (backfill is separate and optional, per above). Rollback is re-applying each function's prior verbatim body (captured via `pg_get_functiondef` immediately before any patch, same as tonight's convention). Test plan before applying: rolled-back-transaction replay of the same 5 real same-machine rows used tonight, confirming `is_internal_move_dispatch` now returns `true`, and a rolled-back call to `wh_approve_remove_receipt` against one of them (or a fresh `add_dispatch_row`-created synthetic same-machine row, once B1 lands) raising the INTERNAL MOVE exception instead of the M2M one.
