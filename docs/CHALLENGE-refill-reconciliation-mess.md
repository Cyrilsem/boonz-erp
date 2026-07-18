# The refill/inventory mess: a perspective, and how I'd fix it

**Author:** Claude (ops/data), for CS · **Date:** 2026-07-16 · **Status:** perspective note, for grouping + prioritisation

---

## My one-line view

You do not have a warehouse bug, a picker bug, or an expiry bug. You have **one structural problem wearing
many costumes: there is no single, structured capture of what physically happened at the machine, so the
system and reality drift apart every day, and every "fix" is a manual forensic reconciliation that itself
adds entropy.** Everything below is a symptom of that. You cannot guard, constrain or migrate your way out
of a capture problem, and every guard added on top of it so far has made the mess harder to see, not smaller.

## The core loop that is failing

1. The engine builds a plan at 8pm (good, deterministic).
2. The driver goes to the machine and does **something different**: out of stock, a Carrefour local buy, a
   substitution, a machine-to-machine transfer, a return.
3. That real action is written in **free text in a Google Doc** ("7 Tamreem Yellow Peach", "fix the expiry",
   "transfer to O1").
4. Days later, someone (now: me) reverse-engineers the Doc back into the database across three tables
   (`pod_inventory`, `warehouse_inventory`, `refill_plan_output`), guessing shelves, products and whether a
   number means "add" or "set".
5. The reconciliation is partial (one table updated, not the others), so the next day starts already drifted,
   and the engine plans against wrong stock, so the driver improvises again. Back to step 2.

This is a **reconciliation-debt spiral**. The volume of manual edits is not the disease; it is the fever.

## The challenges, grouped

**1. Two sources of truth, no reconciliation loop.**
Physical reality lives in a Doc; system reality lives in the DB. Nothing connects them at the moment of the
refill, so the connection is a forensic exercise later. The Doc is unstructured: ambiguous product names
("yellow peach" = Mango), missing shelves, and no distinction between "I added 2" and "the shelf now holds 2".

**2. Writes do not move together (partial-write drift).**
A manual edit updates stock but not the log; a transfer logs one leg not the other; the FE inline qty edit
can **zero a warehouse batch with no offsetting credit** (24 Gatorade units vanished on 11/07 this way).
`pod_inventory`, `warehouse_inventory` and `refill_plan_output` are edited by different paths that do not
fire as one transaction, so they disagree by construction.

**3. Flow semantics are unvalidated and mislabelled.**
(See `docs/tickets/ISSUE-flow-validity-fefo-vs-fifo.md`.) The labels lie: three flows print "FIFO" while
actually doing FEFO; one real FIFO (`adjust_warehouse_stock`, the manual/inline-edit path) ignores expiry
entirely. Planner reads raw stock, executor enforces a pickable view, so the plan names batches pack will
never issue. Operators see "two different truths" and call it a bug.

**4. Batch/expiry fidelity is weak.**
The same product shows 25/11 vs 26/11; "fix the expiry" recurs almost daily. The one-Active-row-per-shelf
index forces batch merges that flatten expiry granularity, which then feeds the FEFO problem above.

**5. Guard-tightening on an unvalidated base.**
We keep shipping guards (provenance checks, drift-kill, slot guard, quarantine) that all assume the base
flow is correct. On a flow that is not yet validated, a guard cements the wrong behaviour and makes it
harder to audit. This is why the FEFO ticket says: validate first, tighten second.

**6. Operational friction and gaps.**
No `superadmin` account exists, so a received PO price is uneditable by anyone (Be-kind 87 vs 128 is stuck
on this). VOX venue-team refills are invisible to the visit clocks. Product naming is inconsistent
("yellow peach"/Mango, "Zero Lemon"/"Zero Peach" mislabelled on the PO). Each is small; together they force
more manual edits.

**7. The churn itself (the thing you asked me to log).**
There are now **several manual edits per machine per refill, every day**, across a growing fleet. Each edit
is a fresh opportunity to introduce drift, and there is no single ledger that says "here is everything that
was changed on machine X today and why". Tracking is becoming unmanageable by hand.

## Why the current direction makes it worse

Every recent effort has been **downstream** of the capture gap: better provenance, drift reconcilers,
availability views, quarantine release. All good and necessary, but they are all cleaning up after the
divergence instead of preventing it. The reconciler that ran drift to zero on 10/07 was full an hour later,
because the source that creates drift (unstructured, partial, day-late capture) was untouched.

## How I would fix it (highest leverage first)

**Fix 1 (the keystone): capture the actual refill at the source, structured.**
Replace the Google Doc with a structured "what I actually did" capture in the driver/FE app: machine, shelf
(picklist), product (picklist, not free text), quantity, expiry, and explicit transfer legs. This single
change removes ambiguity (#1), makes "add vs set" explicit, and gives reconciliation something exact to run
against. Nothing else on this list pays off until capture is structured.

**Fix 2: one atomic write chain.**
Every stock change goes through a single transactional RPC that writes `pod_inventory` + `warehouse_inventory`
+ `refill_plan_output` together, or writes nothing. The `boonz-manual-refill` skill already encodes exactly
this chain by hand: productise it as one RPC so a partial write becomes impossible (kills #2). Transfers are
one call with two balanced legs, never one leg logged and the other lost.

**Fix 3: validate the flows, then relabel, then tighten.**
Execute the FEFO ticket: publish the pick-order of every stock path, make labels match behaviour, fix the one
real FIFO, unify planner/executor onto one pickable view. Only after that, re-enable the parked guards
(slot-guard block, provenance RAISE). This is what makes the system auditable again (kills #3, #5).

**Fix 4: daily automated reconciliation, not forensic.**
A job that diffs physical (structured capture, or a fresh WEIMI count) against system stock every morning and
surfaces the delta per machine, so drift is caught in hours, not discovered days later in a doc. Turns
reconciliation from a person-week into a report.

**Fix 5: close the small gaps.**
Create a `superadmin` (or relax received-PO price edits to `operator_admin`); add product aliases for the
recurring naming drift (Mango/"yellow peach"); capture VOX venue-team refills into the same structured flow.

## What is already done vs what is queued

- Done: `approve_return` provenance fix (PRD-099); drift-kill fleet reconcile to zero (10/07); Dara's
  canonical-availability proposal (P0 view + index) written; the FEFO/flow-validity ticket logged and guards
  deliberately parked.
- Queued and blocked on the keystone: everything in "how I would fix it". None of the downstream guards should
  ship until Fix 1 and Fix 3 land.

## The one thing to decide

Are we going to keep reconciling a Google Doc by hand (this will not scale, and the drift compounds), or do we
invest in **structured capture at the machine + one atomic write + a daily diff**? My strong recommendation is
the latter, and to freeze new guard-tightening until it is in place. Everything else is rearranging the mess.

---
_Companion: `docs/tickets/ISSUE-flow-validity-fefo-vs-fifo.md` (flow semantics), `docs/architecture/DARA-warehouse-availability-canonical.md` (one truth for availability), `docs/refill-updates/RECON-14-15jul-logging-audit.md` (a worked example of the reconciliation cost)._
