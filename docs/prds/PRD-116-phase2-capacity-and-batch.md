# PRD-116 Phase 2 — capacity model (E) and multi-batch shelves (F)

**Date:** 24 Aug 2026 (overnight run) · **Author:** Claude for CS · **Status:** DRAFT — design sketch only, nothing applied, nothing reviewed by Dara or Cody

**⛔ This document is honestly incomplete.** The overnight brief asked for "Dara's design and Cody's constitutional read" on both items. Those are interactive skills meant to be run with CS in the loop, and this was an unsupervised run — I did not simulate a review under either name. What follows is my own design sketch, written so CS/Dara/Cody have a concrete starting point rather than a blank page, not a substitute for actually running those skills. Treat every section below as a proposal to be reviewed, not a decision.

## E — per-product lane capacity model

**Problem.** Every capacity check in the refill pipeline (`v_shelf_capacity.max_stock`, and now the PRD-116c/D fix's "incoming product's own fleet facing") ultimately derives capacity from _the last WEIMI reading for whatever product happened to occupy that lane last_. That's a proxy, not a measurement — it's wrong whenever the lane's physical geometry doesn't match the last product's form factor (a popcorn-tub lane read as "6" because the last WEIMI snapshot was a can product, when a popcorn tub's actual footprint allows 10).

**Sketch.** A `lane_capacity_model` table keyed by `(shelf_id, product_form_factor)` or, if per-shelf geometry isn't captured anywhere yet, a coarser `(machine_model, lane_type, product_form_factor) → max_units` lookup, seeded from a one-time audit (WEIMI history filtered to each form factor's own best-observed max per lane, cross-checked against known physical dimensions where CS has them). `v_shelf_capacity` would then resolve `max_stock` as `lane_capacity_model` for the CURRENT/PROPOSED product's form factor, falling back to today's "last WEIMI reading" logic when no model row exists — an additive, backward-compatible fallback chain, not a replacement.

**Open questions for Dara:** does a `product_form_factor` classification already exist anywhere (pod_products? boonz_products?), or does this need a new column + a one-time manual tagging pass across the catalog? Is per-shelf geometry data available at all, or does the model have to stay at the machine-model/lane-type granularity?

**Rollout sketch:** additive table + view change, `CREATE OR REPLACE VIEW v_shelf_capacity` with the fallback chain, no writer changes required on day one (everything reading `v_shelf_capacity.max_stock` keeps working). Backfill the model table gradually, per product family, verified against real WEIMI history before each family goes live.

**Rollback:** drop the view's new CASE branch (revert to last-WEIMI-only), table can stay (unused, harmless) or be dropped separately.

## F — `pod_inventory` multi-batch (drop `unique(machine, shelf, product)`)

**Problem.** The constraint forces every merge onto one shelf+product row, so a shelf holding two batches of the same product with different expiries collapses to one expiry value (today's merge logic in `receive_dispatch_line` takes `LEAST(...)`, i.e. the older/more conservative expiry survives, and the true per-batch expiry is only preserved on the WH-side row before it's picked). This directly limits how precise FEFO/expiry-sanity work (PRD-114, PRD-116 item I) can ever get at the shelf level.

**Sketch.** Drop `unique(machine, shelf, product)`, add a new key on `(machine, shelf, product, batch_id)` (batch_id already exists as a text field on `pod_inventory`, used inconsistently as a synthetic dispatch-batch tag — this would need to become a real FEFO batch identity, not just a label). Existing `pod_inventory` rows get a synthetic batch_id derived from their current `(expiration_date, created_at)` so no data is lost in the migration itself.

**Writer sweep this implies** (each needs review, not just a mechanical find-replace):

- `adjust_pod_inventory` — currently assumes one row per (machine,shelf,product); needs a batch_id parameter or a "pick the FEFO-earliest batch" default.
- `record_actual_refill` — same assumption, same fix shape.
- `receive_dispatch_line` — the merge-on-receive logic (`WITH archived AS (UPDATE pod_inventory SET status='Inactive'...) ... INSERT ... current_stock = p_filled_quantity + prior_qty`) currently collapses multiple prior batches into one new row with `LEAST(expiry)`. Under F this becomes: match an existing batch by (machine,shelf,product,expiry) and top it up, or insert a new batch row if the incoming expiry doesn't match any existing one — no more forced expiry collapse.
- `receive_po_addition_into_machine` (PRD-016d, shipped this week) — same batch-matching logic needed at the insert site.
- Anything reading `pod_inventory` and assuming one row per (machine,shelf,product) — `v_shelf_capacity`, `v_shelf_expiry_risk`, `v_machine_expiry_batches` (name suggests it may already handle multi-row per shelf; needs a read before assuming), the packing screen's shelf state queries, WEIMI reconciliation (`resync_pod_inventory_from_weimi`) which currently treats WEIMI's single reading per lane as ground truth for a single pod_inventory row — multi-batch shelves make that reconciliation genuinely harder, since WEIMI still only reports one quantity per lane with no batch breakdown.

**Biggest open risk, flagged for Cody:** WEIMI is shelf truth for quantity (per CS's standing rule), but WEIMI has no batch/expiry granularity at all. Multi-batch `pod_inventory` rows can drift from WEIMI's single number in ways that today's single-row model can't, unless the resync logic is rewritten to reconcile against the SUM of a shelf's batches rather than a 1:1 row match. This is probably the load-bearing design question for the whole item, more than the constraint drop itself.

**Rollout sketch:** additive migration (new unique key, backfilled batch_id, old constraint dropped in the same or a follow-up migration), writers converted one at a time behind read-compatibility (every writer sweep item above can ship independently since none of them requires ALL the others to land first — the risk is inconsistent behavior mid-rollout, not breakage). Needs a fixture/golden-suite pass per writer before going live, given how central `pod_inventory` is to expiry and FEFO logic fleet-wide.

**Rollback:** re-add the unique constraint (requires collapsing any multi-batch rows back to one first — NOT a clean rollback once real multi-batch data exists; this is the part that most needs Cody's read before ever applying to prod).

---

## J — the packing screen asks for a flavour WEIMI cannot know

**Added 2026-08-24 from a live blocker at WPP-1002-4300-O1, shelf A13.**

**What happened.** CS tried to swap Be-kind Cluster out for Popit. Two separate defects blocked it, one after
the other, and the workaround was to bypass the UI entirely and call `add_dispatch_row` four times by hand.

**J1 — the "Swap the pod" shelf picker is scoped to today's plan, not to the machine.**
In `src/app/(field)/field/packing/[machineId]/page.tsx` (~line 4886) the option list is built from the
dispatch lines already loaded for the visit:

```js
const shelves = Array.from(new Map(
  lines.filter((l) => l.shelf_id).map((l) => [l.shelf_id, l.shelf_code])
), ([id, code]) => ({ id, code })).sort(...)
```

WPP has 32 configured shelves and 16 live WEIMI slots, but only 3 shelves were in Monday's plan (A02, A05,
A10) — so only those 3 appeared, and A13 was unreachable. This is backwards: a swap is precisely the action
you want on a shelf the plan did NOT already cover. Fix: source the list from `shelf_configurations` for the
machine (or the latest WEIMI slot set), label each option with its current pod from WEIMI, and annotate
rather than exclude the shelves already in the plan. Small, self-contained, belongs on `prd116-fe-dialogs`.

*Related cleanup, not blocking:* WPP has 32 `shelf_configurations` rows against 16 live WEIMI slots. Any
"all shelves" list will show 16 phantoms until that config is trimmed. Worth an audit across the fleet
before J1 ships, or the new picker just trades one confusing list for another.

**J2 — Remove is validated at flavour level against data that only exists at pod level.**
The Add-dispatch-row modal rejected `Be-kind Cluster - Dark Chocolate ×2` with *"Source machine
WPP-1002-4300-O1 does not carry ... no Active pod_inventory > 0"*. The message was true and the guard was
right on its own terms: WEIMI reports only the POD product ("Be-kind Cluster", 2 of 10 on A13), while
`pod_inventory` insists on a flavour, and A13's only Active row was **Be-kind Cluster – Hazelnut ×2**, last
written 17 June. Nobody actually knows which flavour those 2 bars are — the flavour identity is a stale
guess from the last refill, two months stale.

This is the same pod-vs-flavour gap that produced the MPMCC Popit returns queue (PRD-113b) and the Vitamin
Well expiry error, surfacing in a third place. It is a UX consequence of item F, so it should ship with F
or immediately after.

**Proposed behaviour.** For a Remove on a shelf whose WEIMI reading is pod-level:
1. Offer the POD product and quantity ("Be-kind Cluster ×2"), not a flavour dropdown.
2. Let the driver optionally split by flavour ONLY if they can read the wrappers — the same
   "Split by variant" affordance the returns-approval panel already has.
3. If no split is given, record the Remove against the shelf's FEFO-earliest Active flavour row and mark the
   line `flavour_inferred = true` so the warehouse credit and any later reconciliation know the flavour was
   assumed, not observed.
4. Validate existence at POD level (any Active flavour row for that pod product on that shelf, or the WEIMI
   reading > 0), not at flavour level.

**Also worth fixing while in there:** the modal forces `Source: From another machine` locked to the machine
itself for a Remove, which is what triggers the flavour-level `pod_inventory` check in the first place. A
Remove has no meaningful source machine. That self-referencing "m2m" shape is the same one behind the
PRD-116-item-B branch-order bug — worth resolving the two together so the data model stops describing an
in-machine action as a machine-to-machine transfer.

**Workaround until J ships:** call `add_dispatch_row` directly with `source_kind='unknown'` and a NULL
warehouse for the Remove leg, then one `Add New` per incoming flavour with `source_kind='wh'`. That is what
was done for WPP A13 on 2026-08-24 (Remove Be-kind Cluster – Hazelnut ×2; Add Popit Original Cola 4 +
Orange Squeeze 3 + Lemon & Lime 3 = 10, filling the lane to its max).

---

## Item K — Redirect a return to another machine (field re-destination)

**Raised by:** CS, 24 Aug 2026, from a live incident · **Class:** rule glitch + missing affordance
**Depends on:** item B (internal-move branch order), item J2 (pod-vs-flavour Remove) · **Owner:** Dara design → Cody → Stax

### The incident

On the 24 Aug route, JET-1016-0000-O1 A07 was swapped Vitamin Well → Santiveri. The plan's `Remove`
leg (Vitamin Well – Upgrade ×5) was written, as every Remove is, as a **warehouse return**:
`from_warehouse_id = WH_CENTRAL`, `is_m2m = false`, `source_kind = 'unknown'`. The driver did not bring
the five bottles back to the office. He carried them to the next stop on the same route,
OMDBB-1020-0P00-O1, and put them in A16 — the Vitamin Well lane, which was sitting at 1 of 16.

The system had no way to say that. The screen showed *"return Vitamin Well to office"*, the warehouse
queue was waiting to receive five bottles that were never coming, and had anyone approved that receipt
it would have created five units of phantom warehouse stock — the same failure class as PRD-113
(in-machine moves queued as warehouse returns) and PRD-016c (swap-outs double-quarantined), now in a
third shape: **cross-machine field redirection**.

### Why this keeps happening

Every one of these is the same missing concept. A `Remove` leg records that stock *left a shelf*. The
data model then immediately assumes it knows where the stock *went* — the warehouse — and only the
warehouse. Reality has at least four destinations:

| Destination | Today | Handled by |
|---|---|---|
| Back to the warehouse | default, assumed | `wh_approve_remove_receipt` |
| Another shelf of the same machine | retrofitted | PRD-113 `is_internal_move`, `mark_internal_move_legs` |
| Another machine, planned in advance | supported | `swap_between_machines` / `resolve_m2m_donor_legs_v3` |
| **Another machine, decided in the field** | **not supported** | **item K** |
| Written off (expired / damaged) | partial | quarantine + write-off |

The destination is decided *after* the plan is built, often after the row is packed and picked up.
So the affordance cannot live at plan time — it has to live on the packing / driver / returns screens,
and it has to work on a row that is already `packed = true, picked_up = true`.

### What already exists (and what was used on 24 Aug)

`convert_removes_to_m2m_transfer(p_dispatch_ids uuid[], p_dest_machine_id uuid, p_dest_shelf_id uuid,
p_reason text)` does exactly this at the data layer, and it is correct:

- refuses rows that are not `action='Remove'`, are already `is_m2m`, or are
  `item_added` / `cancelled` / `returned`
- requires one source machine, and source ≠ destination
- requires the destination shelf to belong to the destination machine
- creates the paired `Add New` on the destination shelf carrying the source row's `pod_product_id`,
  `boonz_product_id` and quantity (`driver_confirmed_qty` preferred over planned `quantity`)
- sets both legs `is_m2m = true`, a shared `m2m_transfer_id`, reciprocal `m2m_partner_id`,
  `source_kind = 'm2m'`, and — critically — **nulls `from_warehouse_id` on the Remove leg**, which is
  what pulls it out of `v_pending_wh_remove_confirmations`
- does not touch `machine_id`, `shelf_id`, `boonz_product_id` or `dispatch_date` on the source row, so
  `protect_packed_dispatch_row` permits it on a packed, picked-up line

Then `approve_m2m_transfer(transfer_id, caller)` receives both legs, carries the source expiry onto the
destination row, and asserts `SUM(warehouse_stock)` is unchanged before and after — a hard conservation
check that makes phantom warehouse credit impossible by construction.

**This is a backend that has no front door.** The whole of item K is exposing it, plus three defects
that only show up once it is exposed.

### K1 — The affordance (FE, Stax)

On any `Remove` line that is not yet received, on the packing screen, the driver screen and the
warehouse returns-approval panel, add a third choice next to *Confirm return* / *Decline*:

> **Went to another machine** → machine picker → shelf picker → quantity (default: driver-confirmed
> qty) → reason → confirm

Rules for the pickers:

- **Machine list**: all active machines except the source. Sort machines on the same dispatch date's
  route to the top — a field redirect is almost always to the next stop — but do not restrict to them,
  because a driver may divert.
- **Shelf list**: read from `shelf_configurations` for the chosen machine, **not** from that machine's
  dispatch lines. This is the same defect as J1 — building a picker from `lines` showed 3 of WPP's 16
  live shelves. Annotate each shelf with its latest WEIMI `product_name`, `current_stock` and
  `max_stock`, and mark shelves already carrying the same pod product as the recommended destination.
- **Capacity warning, never a block**: if `destination current_stock + incoming qty > max_stock`, warn
  and let the operator continue. WEIMI max is a stale reading, not a physical fact (items C, D, E).
- **Partial redirect**: allow qty < the Remove quantity. The residual stays a warehouse return. This
  needs a split first — see K3.

### K2 — Fix the self-referencing source on the Remove leg

`convert_removes_to_m2m_transfer` sets `source_machine_id = v_src_machine` on **both** legs. On the
destination `Add New` that is right and meaningful (the stock came from JET). On the source `Remove`
it says "this row's source machine is itself", which is the exact self-referencing shape behind the
item-B branch-order bug: `is_internal_move_dispatch` branch 4 returns `false` for anything `is_m2m`,
so branch 5 — the one that would notice `source_machine_id = machine_id` — is unreachable.

For a genuine cross-machine redirect the answer `is_internal_move = false` happens to be correct, so
the 24 Aug fix is safe. But it is correct *by accident*, and it means the internal-move guard
(`tg_block_internal_move_credit`) is not what is protecting the warehouse here — only `is_m2m` +
the conservation assertion in `approve_m2m_transfer` are. Two things should change together:

1. On the source `Remove` leg, leave `source_machine_id` NULL (a Remove has no source machine — it has
   a *destination* machine). Add a `dest_machine_id` concept, or reuse `m2m_partner_id` as the sole
   pointer, rather than overloading `source_machine_id` to mean two different things on two legs.
2. Reorder `is_internal_move_dispatch` so the same-machine test runs before the `is_m2m` early-exit,
   per item B. Until then, any row where `source_machine_id = machine_id AND is_m2m` is invisible to
   the internal-move classifier.

Both are Cody-review items. Neither should ship without a fixture covering: same-machine m2m,
cross-machine m2m, driver-split children of both (PRD-116b makes children inherit `is_m2m`, which
propagates whichever answer the classifier gives).

### K3 — Split before redirect

`convert_removes_to_m2m_transfer` moves whole rows. A driver who returns 3 of 5 and rehomes 2 has no
path. Add `split_dispatch_remove_line(p_dispatch_id, p_qty_to_split, p_reason)` returning a new
sibling `Remove` row that inherits the parent's tagging (the PRD-116b pattern), then convert only the
sibling. This also makes the flavour split of item J2 composable with K: split by flavour first,
redirect the flavour that actually moved.

### K4 — Audit and reversal

- The redirect must be visible as one event, not two orphan rows. The `m2m_transfer_id` already groups
  them; surface it in the machine history for **both** machines ("5 × Vitamin Well – Upgrade received
  from JET-1016, field redirect, 24 Aug") so the OMDBB shelf history explains where stock appeared from.
- Log the redirect to `monitoring_alerts` (or an equivalent operational feed) with source `m2m_field_redirect`
  so redirects are countable. A high redirect rate on one machine is a signal that the plan is sending
  the wrong stock there.
- **Reversal**: there is currently no `unconvert_removes_to_m2m_transfer`. Before approval, reversal
  means nulling both legs' m2m fields and restoring `from_warehouse_id` — write it as an RPC with the
  same guards rather than leaving operators to a manual UPDATE. After approval, the correction is a new
  transfer in the opposite direction, never an edit of the original.
- The destination `Add New` is created with `from_wh_inventory_id = NULL`, so it is deliberately **not**
  FEFO-bound — the units carry the source shelf's expiry, not a warehouse batch. Any binding check that
  counts unbound fill lines (the nightly `from_wh_inventory_id IS NULL` verification) must exclude
  `source_kind = 'm2m'` rows or it will report a false positive every time a redirect happens.

### Acceptance criteria

- [ ] A driver can rehome a removed product to another machine from the packing/driver screen without
      SQL, on a row that is already packed and picked up.
- [ ] The redirected row disappears from `v_pending_wh_remove_confirmations` immediately.
- [ ] `SUM(warehouse_stock)` is provably unchanged across the whole operation.
- [ ] Source pod loses the units; destination pod gains them, carrying the **source** expiry date.
- [ ] Partial redirects work (K3), and the residual stays a warehouse return.
- [ ] Both machines' histories name the counterpart machine and the transfer.
- [ ] The nightly unbound-fill-line check does not fire on redirect rows.

### Precedent set on 24 Aug 2026 (done manually, keep as the reference case)

```
convert_removes_to_m2m_transfer(
  ARRAY['194d55ad-dc13-4c36-b9d2-f7b7037981bc'],   -- JET A07 Remove, VW Upgrade x5, driver_confirmed 5
  '822d386f-e0db-4a51-b201-0731df90f393',           -- OMDBB-1020-0P00-O1
  'eab54e98-aa95-4775-b8b1-eb8eb85a1542',           -- OMDBB A16, Vitamin Well lane, 1/16
  'Field redirect ...')
  -> transfer_id 3c82756d-3e23-4ba5-b9fe-8757ae0f1eb8, 1 line, 5 units
approve_m2m_transfer('3c82756d-...', '82bba4ee-...')
  -> status approved, source_legs_received 1, dest_legs_received 1, wh_delta 0
```

Result: JET A07 → Santiveri Coco Quinoa 4 + Cran Berry 2 only (Vitamin Well cleared);
OMDBB A16 → Antioxidant 6 + Care 1 + **Upgrade 5** (expiry 2026-11-17 carried from JET);
warehouse untouched; zero new rows in either pending queue.
