# PRD-018 — Stax FE tickets (BUG-C surfacing + BUG-E pack-variant prompt)

**For:** Stax (FE). Backend for both is already shipped + Cody-verified (PRD-018). These close the front-end half.
Created 2026-06-04.

---

## STAX-2026-06-04-01 — Surface dispatch-bridge failures on packing/pickup (BUG-C)

**Backend context (done):** `push_plan_to_dispatch` v6 is now per-row resilient — a single bad row no longer
aborts the whole machine, and any row that fails to bridge writes a `monitoring_alerts` row (loud, non-silent)
instead of silently vanishing. Previously a swallowed `EXCEPTION WHEN OTHERS` dropped confirmed items from the
dispatch list with no signal (the 03-Jun symptom: AMZ-1068 VW Reload, AMZ-1057 Pepsi Black + Sunbites, VML
entire refill, OMDCW Al Ain Water all packed but never appeared in dispatch).

**FE work:**

1. On `field/packing` confirm and `field/pickup`, after the confirm call, **reconcile**: every row the operator
   packed/confirmed must appear in the dispatch list. If any confirmed row is missing, show a clear inline
   "Not yet in dispatch — needs attention" banner on that row instead of silently omitting it.
2. Read the `monitoring_alerts` for the machine+date (source = the bridge) and surface them in the packing
   screen's status area, so a bridge failure is visible to the operator and to ops, not hidden.
3. Add a "Retry dispatch" affordance that re-invokes the (idempotent) bridge for the machine — the backend cover-link
   is idempotent, so re-running is safe and creates no duplicates.

**Acceptance:** a deliberately failing row produces a visible banner + a surfaced alert (not a silent drop);
retry bridges it; a fully-clean machine shows no banner. Smoke both screens.

---

## STAX-2026-06-04-02 — Force variant choice when packing a multi-variant pod (BUG-E)

**Backend context (done):** new guard `flag_multivariant_pack_without_variant_confirmation` (the outbound sibling
of PRD-016's returns guardrail-2) fires a `monitoring_alerts` warning when a multi-variant pod is packed without an
explicit boonz-variant confirmation — this also closed guardrail-2's global-pod blind spot. The 03-Jun symptom:
AMZ-1068 packed Red Bull **Regular** but the dispatch list showed Red Bull **Diet**, because the dispatch resolved
the pod's default variant rather than what was packed.

**FE work:**

1. On `field/packing`, when the pod maps to **>1 active boonz variant** (`product_mapping` with multiple Active
   rows for the pod_product), require the operator to **pick the exact variant** before confirming — do not let it
   default silently.
2. Pass the chosen `boonz_product_id` through the pack/confirm call so the dispatch row carries the SAME variant
   that was packed (packed `boonz_product_id` == dispatch `boonz_product_id`).
3. Record the choice on the existing variant-confirmation path so the new guard does not fire on correctly-handled
   packs. Single-variant pods are unaffected (no prompt).
4. **Note on the "mix" pods:** for pods that are intentionally a fleet mix (`is_global_default` + `split_pct` across
   variants, e.g. Barebells, Hunter), the prompt should respect the mix — confirm the variant(s) the operator is
   physically loading, not force a single one. Coordinate the mix-vs-pick UX with CS.

**Acceptance:** packing a 2-variant pod prompts for the variant and the dispatch row matches the pick (0 guard
alerts); a single-variant pod packs with no prompt; a mix pod respects the split. Smoke packing.

---

## Sequencing

Both are FE-only (backend shipped). STAX-...-01 (bridge surfacing) is the higher priority — it makes the
already-fixed BUG-C visible to operators. STAX-...-02 pairs with the PRD-016 returns variant-picker (same
component family). Each goes through Cody for any RPC call-site change per the FE→RPC rule.
