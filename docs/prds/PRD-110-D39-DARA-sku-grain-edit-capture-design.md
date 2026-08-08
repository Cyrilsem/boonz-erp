# PRD-110 · D-39 · DARA DESIGN — capture plan edits at SKU grain

Leg 164 · 2026-08-08 · CS ruling of 2026-08-01: _"CAPTURE EDITS AT SKU GRAIN (option a). Plan-edit
path records the SKU using P1.4 composition truth; Dara designs, the 88 blocked clusters are the
acceptance measure. Until it lands, the miner's refusal behaviour stands (never invent a SKU)."_

---

## ⛔⛔ READ THIS FIRST — THE ACCEPTANCE MEASURE CS NAMED CANNOT BE MET, AND THE REASON IS NOT THE DESIGN

Everything below was measured live on 2026-08-08, over the **same 90-day window and the same cluster
rule `mine_edit_history_v3` actually uses** — not carried forward from leg 85.

| leg 85 said                     | measured today                                          |
| ------------------------------- | ------------------------------------------------------- |
| 100 recurring clusters          | **197** (the history grew; the shape did not)           |
| 9 pinnable (12%)                | **34** pinnable (17.3%)                                 |
| 88 blocked by pod-grain capture | **163** blocked — 159 multi-SKU pods, 4 with no mapping |

Now the part that decides the design:

```
of the 163 blocked clusters:
    2  have a shelf_composition row resolving to exactly ONE SKU   ← D-39(a) would unblock these
    3  have a shelf_composition row resolving to SEVERAL SKUs      ← still ambiguous
  158  have NO shelf_composition row at all
```

⛔ **`shelf_composition` holds 33 rows across 16 shelves on ONE machine. The fleet has 3,072
shelves.** `inventory_events`, its feeder, holds **70 rows** across the same 16 shelves. The P1.4
estimator is in shadow and has never been fed at fleet scale.

⭐ **So D-39(a), built exactly as CS specified it, unblocks 2 of 163 clusters — 1.2%.** The design is
sound; the truth it is told to read does not exist yet for 99.5% of the fleet. This is S-320's shape
in a second organ: **the blocker is evidence, not capability, and no migration fixes it.**

### And a second premise that has to be said out loud

`plan_edits_v3` holds **1,096 rows and every one of them is on a synthetic 2030 fixture date. There
are ZERO real-date v3 edits.** CS's actual edits arrive through the v19 path into
`pod_refill_plan_audit`, which is where all 1,481 real edit rows and all 197 clusters come from.
`record_plan_edit_v3` — the function option (a) says to change — **is not on the path CS uses**, and
will not be until cutover. Wiring SKU capture into it improves the miner's coverage on the day of
cutover and not one day before.

**Neither fact is an argument for skipping the work.** Capture is forward-looking by nature: it can
only ever record edits made after it ships, so the sooner it exists the sooner history accrues. Both
facts are an argument against the acceptance measure, and against building the resolver on the
assumption that composition will answer.

---

## Design problem

`plan_edits_v3` records `pod_product_id`. `planning_pins_v3` targets `boonz_product_id`. 72 of the
156 mapped pods carry more than one SKU (up to 11), so for those there is no function from pod to
product and `mine_edit_history_v3` refuses by name — `pod_maps_to_multiple_boonz_products`. That
refusal is correct and must survive this change: a pin attached to a SKU CS never named would detach
silently the day that SKU left the mix.

The fix is not a better guess. It is to record the SKU **at the moment it is known**. Today the
miner resolves retrospectively, 90 days later, from `product_mapping` — a catalogue that never knew
which SKU the editor meant. The editor knew.

## Proposed schema

```sql
ALTER TABLE public.plan_edits_v3
  ADD COLUMN IF NOT EXISTS boonz_product_id uuid
    REFERENCES public.boonz_products(boonz_product_id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS sku_source  text,
  ADD COLUMN IF NOT EXISTS sku_refusal text;

ALTER TABLE public.plan_edits_v3
  ADD CONSTRAINT chk_plan_edits_v3_sku_provenance CHECK (
        (boonz_product_id IS NOT NULL AND sku_source IS NOT NULL AND sku_refusal IS NULL)
     OR (boonz_product_id IS NULL     AND sku_source IS NULL     AND sku_refusal IS NOT NULL)
  ),
  ADD CONSTRAINT chk_plan_edits_v3_sku_source CHECK (
        sku_source IS NULL OR sku_source IN ('author','composition','sole_mapping')),
  ADD CONSTRAINT chk_plan_edits_v3_sku_refusal CHECK (
        sku_refusal IS NULL OR sku_refusal IN
        ('multi_sku_no_composition','multi_sku_ambiguous_composition','no_mapping','legacy_row'));
```

⭐ **The CHECK is the whole design in one line: a row carries a SKU with a provenance, or it carries
a named reason it has none. Never both, never neither.** A nullable `boonz_product_id` with no
companion column would let "we could not resolve it" and "nobody has looked yet" share a
representation, and the miner would have no way to tell a genuine ambiguity from an unpatched writer.
This is D-29's split-receipt lesson (`gaps_found = 0` means opposite things without the counter) at
row grain. Existing rows backfill to `sku_refusal = 'legacy_row'`, which is honest and greppable.

## The resolver

```sql
CREATE OR REPLACE FUNCTION public.resolve_edit_sku_v3(
  p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_author_sku uuid DEFAULT NULL)
RETURNS TABLE (boonz_product_id uuid, sku_source text, sku_refusal text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public, pg_temp
```

A strict ladder, first rung that answers wins, no rung guesses:

| rung | source                                                               | `sku_source`   |
| ---- | -------------------------------------------------------------------- | -------------- |
| 1    | `p_author_sku`, validated against the pod's mapping for that machine | `author`       |
| 2    | `shelf_composition` for that shelf → **exactly one** SKU             | `composition`  |
| 3    | `product_mapping` for that pod → **exactly one** Active SKU          | `sole_mapping` |
| —    | otherwise `NULL` + a named refusal                                   | —              |

⛔ **Rung order is load-bearing and rung 1 is above rung 2 on purpose.** The author is the only actor
who knows _intent_; composition knows only what is physically there. A shelf holding one SKU today
does not mean the editor meant that SKU — they may be adding the one that ran out. Composition
outranks the catalogue (rung 2 above rung 3) for the opposite reason: on a multi-SKU pod, physical
truth beats a catalogue that lists every SKU the pod could contain.

⛔ **Rung 1 is VALIDATED, never trusted.** An `p_author_sku` that is not in the pod's mapping for that
machine is a refusal, not an override — otherwise the FE becomes a way to pin an arbitrary product to
a shelf, which is the exact failure the miner's refusal exists to prevent.

⛔ **The `machine_id = d.machine_id OR machine_id IS NULL` house rule (from `resolve_fefo_sku_legs_v3`)
binds every rung that reads `product_mapping`.** Machine-scoped row or the global default. Never a
name match, never `[1]` of an arbitrary array — which is what the miner's current
`(array_agg(DISTINCT pm.boonz_product_id))[1]` would become if the `n_boonz = 1` guard were ever
loosened.

## Writer and miner changes

- `record_plan_edit_v3` gains `p_boonz_product_id uuid DEFAULT NULL`, calls the resolver, and stores
  the triple. ⛔ **The parameter must be added with a DEFAULT and the old signature must not be
  dropped in the same unit** — S-71/Wave-2's `pronargdefaults` rule; check `pg_proc` before and after.
- `mine_edit_history_v3` reads `e.boonz_product_id` when present and falls back to its existing
  pod-resolution when it is NULL. ⛔ The existing `n_boonz <> 1` refusal **stays** — it is what
  catches the legacy rows and the unresolvable ones, and removing it is the one change that would
  make the miner start inventing SKUs.
- The receipt gains a coverage counter: clusters resolved by `author` / `composition` /
  `sole_mapping` / refused, so the 1.2% above becomes a number CS watches rather than a number a
  design doc claimed once.

## Acceptance measure — restated, because the one CS named cannot be met

CS named "the 88 blocked clusters". That population is 163 today, and **161 of them are blocked by
missing composition rather than by missing capture**. Proposed instead, all provable this leg:

1. Every new edit carries either a SKU with a provenance or a named refusal. **Zero rows in neither
   state** — enforced by CHECK, asserted by fixture.
2. The resolver never invents: a multi-SKU pod on a shelf with no composition returns `NULL` +
   `multi_sku_no_composition`, and a multi-SKU pod on a shelf whose composition is itself multi-SKU
   returns `NULL` + `multi_sku_ambiguous_composition`. Two refusals, not one — they need different
   fixes.
3. An author-supplied SKU outside the pod's mapping is REFUSED, not stored.
4. The miner's coverage counter is populated and its total equals the cluster count.
5. ⛔ **The 1.2% is asserted, not hidden**: a fixture-computed count of blocked clusters that a
   composition row could resolve today. It is expected to read 2. When P1.4 rolls out it rises, and
   that assertion is the only thing that will tell anyone.

## Tradeoffs and alternatives

**Resolve at mine time instead of at edit time** (cheaper: no schema change, no writer change, just
teach the miner to read `shelf_composition`). Rejected, and it is worth being precise about why: the
miner runs up to 90 days after the edit and would read **today's** composition against a
three-month-old decision. On a shelf whose mix rotated — which is what a multi-SKU pod is for — that
resolves the wrong SKU with full confidence and no refusal. **A retrospective read is not a cheaper
version of capture; it is a different and wrong answer.** It also cannot ever use rung 1, which is
the only rung that scales.

**Option (b), a pod-scoped pin kind** — reopens a settled decision (pin scope is machine + shelf_id +
`EXISTS` on `product_mapping`, never pod identity) and CS ruled against it.

## Cody handoff checklist

- **Article 2/3** — `plan_edits_v3` already has RLS; adding columns changes no policy. S-308 does not
  apply (no new table). Assert `relacl` unchanged across the migration.
- **Article 4** — `record_plan_edit_v3` keeps its role gate and `app.via_rpc` / `app.rpc_name`;
  the new parameter is validated, not trusted.
- **Article 7** — `plan_edits_v3` refuses DELETE (S-136); the backfill must be an UPDATE of
  `sku_refusal = 'legacy_row'` on existing rows, touching nothing else.
- **Article 12** — forward-only; new overload by DEFAULT, old signature not dropped in this unit.
- **Article 16** — the SKU-resolution rule becomes a canonical object (`resolve_edit_sku_v3`) with
  **three** consumers (writer, miner, fixture). ⛔ The miner must READ it, not restate it — the
  house rule for `product_mapping` scoping is already restated in three places in this codebase and
  a fourth would be the one that drifts.
- **PRD-110 LAW 1** — fixture first. LAW 5 — every refusal named, never a silent NULL.

## ⏸️ THE ASK FOR CS (one line, and it is a fork the loop must not pick)

**For a multi-SKU pod, where does the SKU come from — the P1.4 composition estimator, or the editor's
own selection?** Composition is automatic and covers **2 of 163** blocked clusters today (one
machine, 16 shelves of 3,072). The editor's selection covers all of them and costs a SKU picker on
the edit dialog — FE work, DR-6 class, which this loop cannot deploy. The ladder above supports both
and is built so that rung 1 arriving later changes no stored row. **What CS decides is which rung the
build waits for.**
