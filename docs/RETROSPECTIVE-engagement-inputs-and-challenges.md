# Retrospective: what you've been feeding me, and the challenges we keep receiving

**Author:** Claude, for CS · **Date:** 2026-07-16 · **Span:** ~2026-05-12 → 2026-07-16
**Source:** reconstructed from the project memory (the running distilled record of the engagement) + this
session. Dates are approximate where memory carries them.

---

## Part 1 — What you've been feeding me (the inputs)

Over ~9 weeks the inputs have been remarkably consistent in shape. Six streams:

**1. Near-daily refill documents (Google Docs).**
Driver/venue updates per machine, in three buckets you standardised: *engine-refill errors*, *data to fix
(warehouse/pods/log the flow)*, and *driver recommendations*. Processed on 01, 02, 03, 06, 07, 08, 09, 10,
14, 15, 16 July (and the earlier 01/07 Mirdif reconciliation, the 22-May retro). These are the single
highest-frequency input, and the source of most manual writes.

**2. Dashboard screenshots + "why is this wrong?" bug reports.**
The 0/7 dispatch counter (PRD-086), last-visit vs last-plan clocks (PRD-087/088), warehouse-availability
returning 0 on real stock, the `approve_return` provenance error, the "still showing few days ago" refill
list. Usually a screenshot plus a short "this is flawed, fix it."

**3. PRD + `/goal` requests.**
A long series (memory carries PRD-001 through PRD-099). You feed a problem, I write the PRD + goal-command,
Claude Code ships it, you paste back the commit SHA. Cadence picked up sharply in July.

**4. Team clarifications relayed to me.**
Simran and drivers answering my reconciliation questions (batch expiries, source machines, "yellow peach" =
Mango, Barebells = ACTIVATE, Krambal counts, PO prices). You act as the bridge between the ground and me.

**5. Architecture / strategy decisions.**
The warehouse-availability "split active/inactive" question, the FEFO-validity objection, the persona model
(Dara designs, Cody reviews, Stax implements), the metrics registry, capacity harmonisation.

**6. Procurement, onboarding, partnerships.**
Carrefour local buys and POs; onboarding LevelUp / Keen Health / Plaay; VOX expansion commercial models;
the LevellUp gym 4-option slider.

**And continuously: corrections that became standing rules.** No destructive changes / per-row approval;
load the skill before any op; keep the human confirm in cron; no em-dashes in client copy; PRDs live in
`boonz-erp/docs/prds`; validate flows before tightening. These are the guardrails you've taught me.

## Part 2 — The challenges we keep receiving (recurring themes)

Stripped of dates, the same eight problems recur. They are not separate bugs; they are facets of one thing
(Part 3).

**A. Inventory drift and phantom stock — the dominant theme.**
`pod_inventory` vs WEIMI vs `warehouse_inventory` disagree, constantly. Planogram goes stale against WEIMI.
Phantom rows: receive-without-reservation inflates WH; pinned batches; expiry flags on ghosts; NULL-shelf
orphans; the drift-kill fleet reconcile hit zero on 10/07 and refilled within the hour. This is the most
frequent incident class by far.

**B. Stock loss / corruption through the write paths.**
The FE inline qty edit zeroing a warehouse batch with no offsetting credit (24 Gatorade units, 11/07). The
`approve_return` provenance constraint blocking legitimate returns. Manual edits that update one table and
not the others. Stock leaks out of the ledger through paths that don't move atomically.

**C. FEFO vs FIFO, and labels that lie.**
One real FIFO (`adjust_warehouse_stock`, the manual path) ignoring expiry; three flows printing "FIFO" while
doing FEFO; FEFO enforced at pack time but not plan time. The flows cannot be trusted by reading them.

**D. The manual reconciliation churn.**
Several edits per machine per refill, every day, reverse-engineered from a free-text doc into three tables
days later, guessing shelves/products/add-vs-set. The thing you flagged today. Unsustainable by hand.

**E. Engine / FE bugs surfaced by drivers.**
Dispatch qty-edit not saving; "no stock available / forced Not Filled" on stock that exists; swap-product
add errors; refill naming a batch/expiry that doesn't exist; the 0/7 counter; the two clocks reading
differently. Recurring across almost every refill doc.

**F. Planner vs executor divergence.**
The planner reads raw stock, the executor enforces a pickable view. The plan promises what pack won't
deliver. Root cause behind many "the refill is wrong" reports.

**G. Operational gaps that force more manual work.**
No `superadmin` account → received-PO prices uneditable by anyone. VOX venue-team refills invisible to the
visit clocks. Product-name drift (Mango/"yellow peach", Zero Lemon/Zero Peach mislabels). Scheduler running
on the wrong timezone (UTC+8), firing the 8pm advisory before its data exists.

**H. The guard-on-unvalidated-flow trap.**
We keep shipping guards (provenance, drift-kill, quarantine, slot-guard) that assume the base flow is
correct. On an unvalidated flow, a guard cements the bug. You called this out explicitly.

## Part 3 — The through-line

Every one of A–H is downstream of **two missing primitives**:

1. **No structured capture of what physically happened at the machine** (F1). The truth enters the system as
   free text, days late, and has to be guessed back into the schema. That produces D directly, and feeds A,
   E, F, G.
2. **No atomic write that moves pod + warehouse + log together** (F2). Because the three tables are edited by
   different paths that don't co-commit, they disagree by construction. That produces B directly, and feeds
   A and C.

Everything we've shipped so far (provenance fixes, drift reconcilers, availability views, quarantine
release) is **cleanup after the divergence**, not prevention. That is why the drift reconciler runs to zero
and refills within the hour: the two primitives that create the divergence were never built.

## Part 4 — The decision this leads to

Stop reconciling a document by hand, and build the two missing primitives:

- **F1 — structured capture at the source** (picklist machine/shelf/product/qty/expiry/transfer-legs), so
  the truth enters the system exactly once, correctly, at the moment of the refill.
- **F2 — one atomic `record_actual_refill` RPC** that writes pod + warehouse + log in a single transaction
  (or nothing), wrapping the chain the manual-refill skill performs by hand today.

With those two in place, C/E/F become validation work (the FEFO ticket), and G is a short punch-list. Without
them, we keep paying the reconciliation tax daily and it compounds.

_Companion: `docs/CHALLENGE-refill-reconciliation-mess.md` (the fix plan), `docs/tickets/ISSUE-flow-validity-fefo-vs-fifo.md`,
`docs/architecture/DARA-warehouse-availability-canonical.md`._
