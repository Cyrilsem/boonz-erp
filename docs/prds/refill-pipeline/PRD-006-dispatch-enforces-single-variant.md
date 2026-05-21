---
id: PRD-006
title: Dispatch picking enforces a single variant for multi-variant SKUs
status: Blocked
severity: P1
reported: 2026-05-21
source: Refill update 21-05-2026 — YoPro, Be Kind, Perrier across multiple machines
routing: [Stax, Dara]
protected_entities: [pod_inventory, warehouse_inventory, refill_plan_output]
blocked_reason: |
  product_family_id schema landed (supabase/migrations/20260521233552_prd002_006_product_families.sql,
  unapplied) — the schema prerequisite shared with PRD-002 is unblocked. Per
  RPC_REGISTRY, propose_add_plan v2 already does G3 multi-variant split, so
  Stitch is writing variant rows — the bug is the picking UI collapsing them.
  FE fix still needs a new substitution log table from Dara AND picking-RPC
  changes whose body is in the live DB. Reconcile credit-back of intents-scoped
  substitutions also requires reconcile_intent_progress body access.
---

# PRD-006 — Dispatch picking enforces a single variant for multi-variant SKUs

## Problem

Multiple machines on 2026-05-21 showed the same class of issue: the refill plan asked for a mix of variants of the same product family, but the dispatch / picking app collapsed the request to a single variant.

Concrete instances from the source doc:

- **OMDCW-1021 YoPro:** 3 pieces returned, all vanilla. The plan asked for different flavors. Need to determine whether the driver picked 3 vanilla by choice or was forced by the app.
- **VML 4F Perrier:** 1 Regular shown in the plan, but no Regular available in stock — the picking flow should have prompted for a Strawberry replacement.
- **VML 5F Be Kind Cluster:** plan asked for 1 Dark + 2 Peanut Butter; driver packed 3 Peanut Butter.
- **Nook Cookies & Cream:** similar pattern — substitution made on the ground because the picking flow did not give a structured fallback.

This bug sits at the seam between Stage 3 Stitch (which resolves to boonz_product/SKU) and the dispatching app the driver uses. Either Stitch is collapsing variants on its way out, or the picking app is not displaying variant-level granularity.

## Observed behaviour

For YoPro, Be Kind, Perrier (and any product with multiple variants under one family): the driver sees a single line with a single variant, picks N units of whatever's available, regardless of the planned variant mix.

## Expected behaviour

- The refill plan must express variant intent explicitly at the line level (e.g. `Be Kind Dark Chocolate x1, Be Kind Peanut Butter x2`)
- The picking UI must show each variant as a distinct line with its own qty
- If a planned variant is out of stock, the picking UI must offer a structured replacement: prompt for either a different variant in the same family, or a different boonz_product entirely, capturing the substitution in `refill_plan_output_substitution` (or equivalent) for reconciliation

## Hypothesis on root cause

Two candidate failure modes — investigation should triage in this order:

1. **Stitch resolves to family-level boonz_product, not variant-level SKU.** Stage 3 Stitch (per refill-brain skill) writes to `refill_plan_output`. If the rows are keyed by family product, variant intent is lost before it ever reaches the driver. Check the join between `product_mapping` and `warehouse_inventory` in Stage 3.
2. **Picking UI groups by family product on render.** Even if Stitch writes variant-level rows, the FE may group them visually and let the driver "pick from the family" without committing to a variant. Check the driver app's render of `refill_plan_output`.

Both root causes need fixing if both are true.

## Scope

In scope:

- Stage 3 Stitch output schema and the way it expresses variant intent
- Picking UI variant rendering and substitution capture flow
- Substitution log table (Dara, if it doesn't exist)
- Reconcile: substitutions should credit strategic intents where the substitute is in the same intent scope

Out of scope:

- Returns-side variant handling (see [[PRD-002-returns-split-by-variant-ui]] — should reuse the same UI patterns)
- Multi-variant onboarding for new SKUs (planogram concern)

## Protected entities touched

`pod_inventory`, `warehouse_inventory`, `refill_plan_output`. Dara may need to add a substitution log table; Cody reviews the picking RPC.

## Acceptance criteria

- [ ] Refill plan for a machine with planned variant mix (e.g. Be Kind 1 Dark + 2 PB) shows two distinct lines to the driver
- [ ] Driver sees variant name in each line, not just family name
- [ ] If a planned variant is out of stock, driver gets a structured choice list (other family variants → other family products), with a quick "use same family alt" path
- [ ] Substitution captured: `{plan_line_id, planned_variant, substituted_variant, qty, reason}` row written on save
- [ ] Reconcile credits intents correctly when substitution is within an intent's scope
- [ ] Regression: VML 5F Be Kind and OMDCW YoPro re-tested in staging

## Edge cases (all must verify before marking Done)

- **Planned variant qty = 0:** line skipped entirely, no UI clutter.
- **Substitution variant_id == planned variant_id:** rejected (that's not a substitution, that's a normal pick).
- **Substitution outside the family (cross-family):** allowed per Decisions, logged with `signal_source = cross_family` so the brain sees the divergence.
- **Driver saves with zero picks AND zero substitutions:** rejected (invalid empty state).
- **Multiple substitutions for one plan line:** allowed; reasons chained in the substitution log.
- **Substitution target not in product_mapping:** rejected with explicit "no SKU mapping" message.
- **Family with only one variant:** behaves identically to a single-SKU line (no variant picker shown).
- **Plan asks for variant currently out of WH stock at pick time:** picking UI prompts for substitution before allowing save.

## Verification

- [ ] `npx tsc --noEmit`, `npm run build`, `npm run lint`
- [ ] Manual end-to-end test with two variants of one family
- [ ] Inspect `refill_plan_output` row count after stitch — variant-level granularity confirmed
- [ ] Cody review

## Decisions

- **Variant model:** distinct `boonz_product_id` per variant, grouped by `product_family_id`. Same call as [[PRD-002-returns-split-by-variant-ui]] — locked in across both PRDs. If the current schema uses a single product + variant column, a Dara migration bundles into the earliest of the two PRDs to ship.
- **Substitution gating:** ALWAYS EXPLICIT acknowledgement. The driver taps "substitute" and selects the replacement variant. Auto-substitute is forbidden — silent substitution destroys the brain's signal (it can't tell whether the planned variant sold or whether something else sold in its place). Cost of one extra tap is trivial compared to corrupted demand data.
- **Variant mix enforcement:** SUGGEST + LOG DEVIATION. Show the planned mix as the default qty per variant; allow the driver to override, but log the deviation with reason code. Drivers know things the brain doesn't (damaged unit, weird truck stocking). Hard-enforce and they'll lie; pure-suggest and we get no data — suggest+log is the right middle.
- **Brain feedback latency:** SUBSTITUTION LOG IS REAL-TIME for procurement (procurement needs "we substituted Be Kind Dark → Peanut Butter 12 times this week, order more Dark"). BRAIN CONSUMES VIA MORNING BATCH RECONCILE (existing reconcile step in refill-brain Stage 5). Decouples the procurement signal from the planning cycle so neither blocks the other.

## Linked PRDs

- [[PRD-002-returns-split-by-variant-ui]] — same variant model, return side
- [[PRD-008-refill-plan-shows-phantom-skus]] — variants tagged in plan but missing from WH may also surface here
