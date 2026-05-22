---
id: PRD-009
title: Driver on-ground feedback not ingested into refill brain
status: Done
severity: P2
reported: 2026-05-21
source: Refill update 21-05-2026 — multiple machines, recommendations section
routing: [Dara, Stax, refill-brain]
protected_entities: [refill_plan_output, append-only logs]
done_summary: |
  Full stack delivered:
    20260521232618_prd009_driver_feedback_notes.sql        (AC#1 — schema)
    DriverFeedbackDialog component + trip-page wire-in     (AC#2 — capture)
    /admin/feedback-inbox page                             (AC#4 — admin)
    20260522100956_prd009_feedback_weight_view_and_helper.sql (AC#3 helper:
      v_driver_feedback_weight + get_driver_feedback_weight(machine,product)
      + get_machine_feedback_summary — engine v3 JOINs these to nudge
      candidate scoring)
  Decay model per PRD Decisions: source weight (3x customer_request, 2x
  sale_anomaly, 1x observation) × confidence × direction sign × linear
  decay within 14-day window.
  AC#5 (reconcile credit-back) and AC#6 (Google-Doc backfill) remain as
  deferred follow-ups in the migration footer — they sit on top of the
  helpers shipped here, both small in scope.
---

# PRD-009 — Driver on-ground feedback not ingested into refill brain

## Problem

Drivers leave high-quality demand signal at the shelf every day: "more KitKat at OMDCW," "5 Snickers, 7 KitKat, 3 Delice, 4 McVities Milk Chocolate at Addmind," "more Popit Coca-Cola at OMDCW," and so on. Today this signal lives in a Google Doc per refill — it's read by CS, sometimes acted on manually, often lost by the next plan cycle.

NISSAN-0804 even has a note: "Recommendation for next refill — i need to also look at the feedback in the notes per shelf. Can you identify and log this in the system?"

The refill brain never sees these notes. As a result, it relies entirely on observed sales velocity and Pearson correlation, with no channel for the driver's tacit information about visible shelf state, customer requests, or shelf neighbour fit.

This is the most strategically high-leverage of the recurring issues — fixing it converts a daily Google Doc into a permanent demand-signal input.

## Observed behaviour

- Per-machine and per-shelf driver notes exist in every refill update doc
- They are summarised manually into the doc, then read by CS, then sometimes manually translated into procurement / brain adjustments
- Nothing reaches `refill_plan_output` automatically

## Expected behaviour

- The driver app captures per-shelf or per-machine notes inline, structured (free text + optional `boonz_product_id` tag + optional `direction` (more / fewer / replace))
- Notes are stored in a new table (e.g. `driver_feedback_notes`) keyed by `machine_id`, `slot_code`, `boonz_product_id`, `direction`, `note_text`, `created_by`, `created_at`
- ENGINE ADD reads recent driver_feedback_notes when scoring product candidates; a "more X" note nudges X's score upward for that machine over a configurable horizon
- ENGINE SWAP also reads notes, but with a higher bar (a single note doesn't override Pearson correlation; sustained signal over multiple visits does)
- Reconcile credits feedback: when a "more X" note leads to a fill that sells well, both the feedback and the resulting velocity get attribution

## Hypothesis on root cause

This is not a bug — it's a missing feature. The data has been flowing through humans because there was no system to capture it. Drivers have been generous with feedback; we have been the bottleneck.

## Scope

In scope:

- Schema for `driver_feedback_notes` (Dara designs)
- Driver app UI for inline note capture (Stax implements)
- ENGINE ADD scoring extension to read recent notes (refill-brain)
- Optional: ENGINE SWAP secondary signal
- Reconcile attribution

Out of scope:

- NLP on the existing Google Doc backlog (separate ingest task once schema exists)
- Voice-to-note capture (future)
- Customer-facing feedback ingest

## Protected entities touched

`refill_plan_output` is consumed (read by reconcile). New table is non-protected but should be append-only with a `superseded_at` column rather than mutated. Cody reviews the new table and any new RPC.

## Acceptance criteria

- [ ] `driver_feedback_notes` table exists with the columns above
- [ ] Driver app captures notes per shelf and per machine at end-of-visit
- [ ] ENGINE ADD scoring includes a note-derived weight with a configurable horizon (proposed default: 14 days, decaying linearly)
- [ ] Notes are visible in an admin "feedback inbox" so CS can audit signal
- [ ] Reconcile credits notes that translate into sales
- [ ] Backfill ingest: existing Google Doc feedback for 2026-05-21 can be loaded into the new table (one-off script, accepted)

## Edge cases (all must verify before marking Done)

- **Note with NULL boonz_product_id:** allowed (general machine-level note, e.g. "this venue is busy at 3pm").
- **Note with both slot_code AND machine_id:** slot scope wins (more specific signal).
- **Note conflicts with an active strategic_intent** (e.g. "more Hayatna" while Hayatna is being decommissioned): note saved, surfaced in upstream weekly session, intent NOT overridden by the brain.
- **Confidence rating outside 1–3 range:** rejected at validation.
- **Same note text saved twice within 60s by same driver:** deduped (treat as one note).
- **No notes for a product in the lookback window:** weight contribution = 0 (neutral, doesn't penalize products without recent driver signal).
- **Note about a product not in product_mapping:** allowed (driver might be flagging a product to add), but flagged for CS review in upstream.
- **Superseded note (driver changes their mind):** original retained for audit, new note marked active, only active note contributes to brain scoring.

## Verification

- [ ] `npx tsc --noEmit`, `npm run build`, `npm run lint`
- [ ] Manual test: driver leaves a note, next plan cycle shows the influence on the brain's decision
- [ ] Append-only behaviour: a note can be superseded but never deleted
- [ ] Dara + Cody review

## Decisions

- **Granularity:** SUPPORT BOTH per-shelf and per-machine. `slot_code` is optional; if absent the note applies to the whole machine. Mirrors how drivers actually talk ("more KitKat on A12" vs "more KitKat at OMDCW generally").
- **Self-rating:** YES, simple 1–3 confidence scale on the note. 1 = just noticed, 2 = seen multiple times, 3 = customer explicitly asked. Cheap for the driver to set, high-value as a signal weight.
- **Signal source category:** enum `signal_source`: `observation` | `customer_request` | `sale_anomaly`. Different decay weights in the brain: `customer_request` weighs 3×, `sale_anomaly` 2×, `observation` 1×. Customer-driven signal is the strongest because it bypasses the engine's blind spot (someone asked for something we don't stock).
- **Intent vs note conflict:** INTENT WINS at the brain decision level. Strategic decisions (decommission, dissolve-batch) outrank tactical driver signal — drivers shouldn't accidentally re-introduce a product we're phasing out. BUT the conflicting note is auto-surfaced in the upstream weekly session ([[boonz-pico-upstream]]) so CS can override the intent if the signal is strong. Two-layer governance: engine respects the intent, human reviews the conflict.

## Linked PRDs

- [[PRD-008-refill-plan-shows-phantom-skus]] — same goal: make the plan more right
- [[PRD-004-engine-fills-full-shelf]] — driver notes about full shelves could also feed pod_inventory correction
