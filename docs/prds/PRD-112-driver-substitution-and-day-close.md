# PRD-112 — Driver Self-Service Substitution + Day-Close Panel

**Status:** APPROVED by CS 2026-08-08 · **Owner:** Stax-class unit, executable by Claude Code
**Principle (CS, verbatim intent):** the driver is NEVER blocked at the machine. He changes the
product in the system himself, keeps moving, and the changes surface as a reviewable note at end
of day where CS closes the loop (inventory closed, refill closed, gaps acknowledged).
**Repo:** boonz-erp. **Scope:** field PWA + one admin panel + 2 narrow RPCs. NO engine changes.

## 1. Problem

Live incident 2026-08-08 (VOXMCC-1005): plan said Fade Fit Dark Choc/Hazelnut/PB/Salted Caramel;
venue only had Coconut. Driver had no self-service path: FE add-row hit the duplicate guard,
packed-row guard blocked edits, resolution required CS intervention mid-route. Substitution at
venue is ROUTINE (venue flavor availability, spot buys, shortfalls) — the system must absorb it
at the edge and reconcile centrally, not force synchronous approvals.

## 2. What already exists (reuse, do not rebuild)

- `refill_dispatching.driver_confirmed_qty / _at / _by / _breakdown` — driver confirm columns.
- `remove_dispatch_row` / `add_dispatch_row` — canonical dispatch-edit writers (Title Case
  actions; add creates rpo-orphans that need rpo backfill — see 4.2).
- `/refill/drift` page + drift candidate table (planned vs filled, qty_gap, review status).
- The 20:00 Dubai advisory email (Cowork scheduled task) — day-close summary can append to it.
- Guards that must KEEP working: duplicate-unstarted-row guard, packed/picked-up row protection
  (goods in motion), conservation checks. We route around them with a purpose-built RPC, we do
  not weaken them.

## 3. Design

### 3.1 New RPC: `driver_substitute_dispatch_line` (SECURITY DEFINER, Cody review required)

Args: `p_dispatch_id, p_new_boonz_product_id, p_filled_qty, p_reason text, p_actor uuid`.
Behavior, atomic:

1. Validate: line exists, dispatch_date = today (Dubai), caller role in (field_staff,
   warehouse, operator_admin). Line may be packed/picked_up — that is the NORMAL case; this RPC
   is the sanctioned bypass of the packed-row guard (it re-labels, it does not delete).
2. Guard: new product must be an ACTIVE boonz product. If the line's machine is co_managed
   (VOX) and the line is venue-sourced: any product mapped venue_team on that machine is allowed
   (flavor freedom). If Boonz-sourced: new product must have WH stock OR the call is tagged
   `spot` (driver bought it) — never hard-block; if stock validation fails, still accept but
   set `needs_review = true, review_reason = 'substitution_stock_unverified'`.
3. Write: update `boonz_product_id`, set `filled_quantity = p_filled_qty`,
   `driver_confirmed_qty/_at/_by`, append audit comment `SUBSTITUTED by driver: <old> -> <new>
(<reason>)`, keep original product in `original_boonz_product_id` (column exists), rebind
   `from_wh_inventory_id` to the new product (sentinel for venue lines, FEFO for WH lines,
   NULL + needs_review if no batch).
4. Log one row into a new lightweight `day_close_events` table (see 3.3): kind='substitution'.
5. NEVER raise for business reasons. Only raise for malformed input. The driver moves on.

### 3.2 Field PWA: "Change product" button

- On each dispatch line in `/field/packing/[machineId]` (and the driver trip line view): button
  `Change product`. Modal: product picker (venue-mapped products first for VOX machines),
  actual qty filled, optional reason chips (`venue had different flavor`, `out of stock`,
  `spot buy`, `other`). Submits the RPC. Success toast, line re-renders with new product and a
  small `SUB` badge. Two taps, under 10 seconds, zero approvals.
- The existing add-row modal stays for genuinely NEW lines; its duplicate error message gains
  one line: `This product already exists on this shelf — use Change product on that line.`

### 3.3 Day-Close panel (the "note" in /refill) — NOT an email cron

New table `day_close_events` (id, event_date, machine_id, dispatch_id, kind, payload jsonb,
created_by, acknowledged_at, acknowledged_by). Kinds: `substitution`, `not_filled`, `shortfall`,
`spot_buy`, `stock_unverified`.
New card/tab on `https://boonz-erp.vercel.app/refill`: **"Day Close"** showing for the selected
date:

1. **Changes** — every substitution (machine, shelf, old -> new, qty, driver, reason).
2. **Gaps** — not-filled lines, unfilled shortfalls, drift candidates still open.
3. **Close checks** (computed live, red/green): all dispatched machines received? ·
   all packed lines picked up? · any needs_review rows? · returns pending manager receive? ·
   pod_inventory adjustments pending for substituted lines?
4. **[Acknowledge all] / per-row acknowledge** — writes acknowledged_at. The pod_inventory
   correction for substituted lines fires on acknowledge (calls the existing
   `adjust_pod_inventory` merge path), so machine stock truth follows CS's confirmation, same
   evening, one click. Nothing auto-writes stock without the acknowledge.

- The existing 20:00 advisory email appends one line: `Day Close: N changes, M gaps open ->
/refill (Day Close tab)`. No new cron.

## 4. Hard constraints

1. Cody reviews the RPC + table migration (SECURITY DEFINER, touches refill_dispatching —
   protected). The packed-row guard stays; the RPC is the single sanctioned writer through it.
2. `add_dispatch_row` rpo-orphan behavior: substitution RPC must keep the linked rpo row's
   boonz_product_name in sync (update the rpo row by dispatch_id) so FE boards do not diverge.
3. No auto stock writes at substitution time. Stock truth moves ONLY at day-close acknowledge
   (CS) or the normal receive flow. Expired/returns rules untouched.
4. Settlement safety: `original_boonz_product_id` preserved so VOX SOA reads actual sold/filled
   product, and the vox commercial mapping resolves the NEW product name.
5. v3 compatibility: `day_close_events` is exactly the shape the v3 edit-miner consumes; name
   fields per RPC_REGISTRY conventions. At cutover this panel keeps working unchanged.

## 5. Acceptance

1. Driver (field_staff jwt) substitutes a venue line flavor on a packed+picked_up line in <10s,
   no error, audit comment + original product preserved, rpo in sync.
2. Boonz-line substitution with no stock: accepted, flagged needs_review, appears in Day Close.
3. Day Close shows the substitution immediately; acknowledge writes pod_inventory via
   adjust_pod_inventory merge; re-acknowledge is idempotent.
4. Close checks reflect live state (verified against a day with 1 unreceived machine).
5. Duplicate-row guard message updated; guards otherwise byte-identical.
6. Golden: run_all green after migration; new fixture: "driver substitutes flavor on packed
   line; day-close acknowledge closes inventory" (the 08-08 Coconut incident, encoded).
7. Build green, Vercel preview walked, merge to main.

## 6. Execution notes for Claude Code

- Single-session task, branch `prd-112-driver-substitution`. Backend first (migration + RPC +
  Cody review paragraph in the PR description), then FE. May run after PRD-111 merges (shares
  field files); rebase if needed. Do not touch PRD-110 loop files (docs/prds/PRD-110*,
  supabase/migrations belonging to the loop are append-only — add your own new migration files).
- Test against synthetic 2030 dates for the fixture; live smoke on a 1-unit line only.
