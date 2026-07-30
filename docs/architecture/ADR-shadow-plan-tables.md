# ADR - Shadow plan tables for PRD-110 Phase 2 (`pod_refill_plan_shadow`)

- **Status:** ACCEPTED (design-time). Signoff required by Constitution **Article 14**.
- **Date:** 2026-07-30
- **Context:** PRD-110 Refill Engine v3 "One Brain", Phase 2 (`engine_add_pod_v3`).
- **Closes:** PARKING-LOT **S-03**, ADR half. (The cheat-sheet half was fixed in relay leg 2:
  `.claude/skills/cody/SKILL.md` Article 14 corrected in three places.)
- **Supersedes nothing.** Forward-only, Article 12.

---

## 1. Why this ADR exists at all

Article 14, stated precisely (verbatim from `01_constitution.html`):

> No snapshot tables **when a view suffices**; new tables that materialize a query result
> **for performance reasons** require ADR signoff.

`pod_refill_plan_shadow` materializes engine output. That is a query result made durable, so the
second clause applies and this document is the required signoff. It is **not** caught by the first
clause, and section 3 proves why: a view cannot produce this data at all.

⚠️ The Cody cheat sheet used to say Article 14 bans `_v2` / `_new` parallel tables outright, and
listed that as an auto-refusal. Under that (wrong) reading, `pod_refill_plan_shadow` and PRD-110
**LAW 4** ("SHADOW, DON'T SWITCH") would be unconstitutional - the goal command's central safety
mechanism would be illegal. The real article says nothing about name suffixes. The operative test is
**silent staleness**, not the name. That is the test section 5 answers.

## 2. Decision

Create a **shadow plan table**, `pod_refill_plan_shadow`, that `engine_add_pod_v3` writes instead of
`pod_refill_plan`, plus whatever sibling shadow tables Phase 2/3 need on identical terms
(`pod_refills_shadow` if the stitch ladder needs a shadow line table at P3.1).

Structure: **column-compatible with the live table** - same grain, same keys, same action vocabulary
(Title Case), same `reasoning` jsonb - plus three shadow-only columns:

| Column        | Purpose                                                                                        |
| ------------- | ---------------------------------------------------------------------------------------------- |
| `run_id`      | uuid, one per engine invocation. Makes re-runs additive-and-distinguishable, never destructive |
| `engine_tag`  | text, e.g. `engine_add_pod_v3`. The diff must never guess which engine produced a row          |
| `produced_at` | timestamptz. Ordering for "latest shadow run for this plan_date"                               |

The nightly diff (v3 shadow vs v19 live) is a **VIEW** over this table joined to `pod_refill_plan`,
not a second materialization. WMAPE telemetry likewise.

## 3. Why a view does not suffice (the Article 14 first-clause test)

A view returns a function of _current_ inputs. The shadow rows are a function of the inputs **as they
were at engine-run time**, which are gone by morning:

1. **WEIMI stock moves continuously.** The engine reads shelf stock at 20:00 Dubai. By the time the
   diff is read the same shelves have sold. A view would silently re-plan against different stock and
   the diff would compare a fresh v3 answer against a stale v19 row - a comparison of two different
   questions, reported as a discrepancy.
2. **The engine is not a query.** `engine_add_pod` is `plpgsql`, procedural, with clamps, bands,
   FEFO walks and tag consumption. It cannot be expressed as a `SELECT`. This is the decisive point:
   there is no view to write, at any performance cost.
3. **The comparison is longitudinal.** The Phase 2 gate is "2 weeks shadow; WMAPE(v3) ≤ WMAPE(v19)".
   That requires **history** - 14 days of what v3 said on each of 14 nights. A view has no memory.
4. **`pod_refill_plan` itself is a table for the same reason.** The shadow table is the same kind of
   object as the thing it shadows. If the live plan needs to be durable, so does its shadow.

So the "view suffices" clause is not merely inconvenient here; it is inapplicable. The materialization
is not **for performance reasons** either - it is for _correctness of the comparison_. Under a strict
reading the second clause may not even bind. The ADR is written anyway, because the honest test is
staleness and staleness deserves an answer on the record.

## 4. Why not write to the live table with a flag column

Rejected. Adding `is_shadow boolean` to `pod_refill_plan` would:

- put non-plan rows inside a **protected entity** that dispatch, stitch, preflight, the FE and the
  8pm advisory all read, every one of which would need a `WHERE is_shadow = false` predicate added
  before the first shadow row landed. One missed predicate dispatches a driver against a shadow plan;
- violate **LAW 12** ("never touch live plan tables for dates with non-pending rows") by construction,
  since shadow runs target _real_ dates - that is the whole point of a shadow;
- make rollback destructive (a `DELETE` from the live plan table) instead of a `DROP` of an isolated
  object.

A separate table makes the blast radius exactly zero: no existing consumer knows the shadow exists.

## 5. Staleness - the real Article 14 risk, and the guarantees against it

The danger the article actually guards is a materialized copy that **drifts and is trusted anyway**.
Four binding guarantees:

1. **Write-once per run, never updated.** Rows are INSERTed with a `run_id` and never UPDATEd. A
   stale row is impossible because no row is ever meant to track a moving input - each row is an
   immutable record of "what v3 said at `produced_at`". This is a **ledger**, not a cache. (Same
   argument that exempted `blocked_demand` from needing an ADR at all.)
2. **No consumer of truth.** Nothing operational reads it. Not dispatch, not stitch, not preflight,
   not the FE, not the advisory. Readers: the diff view, WMAPE telemetry, the scoreboard, and CS.
   A stale shadow row therefore cannot cause a wrong action - only a wrong _report_, and (1) makes
   even that impossible.
3. **`engine_tag` + `produced_at` on every row.** Any reader that wants "the current shadow plan"
   must name a run. There is no unqualified read that could quietly return yesterday's answer.
4. **Retention is bounded and stated:** shadow rows older than 90 days are droppable without loss
   (the scoreboard aggregates are the durable artifact). Purge is a manual, logged operation - never
   a cron that could race a diff mid-read.

## 6. Consequences

**Accepted:**

- One extra table per shadowed plan object, plus its diff view. Storage is trivial (a fleet-night of
  plan rows is ~10²).
- The v3 engine has a second write target to maintain until cutover. This is the explicit price of
  LAW 4 and is cheaper than the alternative (a wrong live plan).

**Enabled:**

- Phase 5 cutover becomes a **flag flip**, per cluster, with 2 weeks of evidence behind it, and a
  rollback that is "stop writing shadow" rather than "undo a plan".
- `engine_add_pod` v19 is never modified, so the Family-A freeze and **LAW 3** hold, and every
  existing golden fixture keeps its baseline.
- S-13 (v19's `velocity_30d` unit inconsistency) can be corrected in v3 **without moving a single
  live quantity**, because v3's quantities land in the shadow table. This is the ADR's largest
  practical payoff: the three-way unit disagreement is unfixable in place under the freeze.

**Costs if we are wrong:** if shadow and live diverge for a reason nobody notices, cutover ships a
worse engine. Mitigation is the gate itself (CS reviews 3 shadow plans line-by-line) plus fixtures
2/7/8/14/15, not this ADR.

## 7. Constitutional review (Cody, class (a) DDL)

| Article | Verdict | Note                                                                                                                                                                                                                                                                  |
| ------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1       | ✅      | One writer: `engine_add_pod_v3`. No other code path may INSERT. Shadow table is NOT a protected entity.                                                                                                                                                               |
| 2 / 3   | ✅      | RLS on, `anon` REVOKEd, reads limited to operator/manager roles + service. New views `security_invoker = true`.                                                                                                                                                       |
| 4       | ✅      | Writer validates `plan_date`, refuses a date with non-pending live rows (LAW 12) exactly as the live engine must.                                                                                                                                                     |
| 8       | ✅      | Append-only by design; `run_id` + `produced_at` are the audit trail. Generic write-audit trigger applies if attached.                                                                                                                                                 |
| 12      | ✅      | Forward-only. New objects only; nothing dropped, nothing downgraded, no existing signature changed.                                                                                                                                                                   |
| **14**  | ✅      | **This document is the signoff.** Sections 3 and 5 carry the argument.                                                                                                                                                                                                |
| 16      | ✅      | Register `pod_refill_plan_shadow` in METRICS_REGISTRY as the canonical object for "v3 proposed plan (shadow)", explicitly disjoint from `pod_refill_plan` ("approved plan"). The diff and WMAPE each get exactly one canonical object; no consumer re-derives either. |

## 8. Obligations on the leg that creates the table

Not optional - this ADR is signoff for a design, and the design includes its own proof:

1. Register in `MIGRATIONS_REGISTRY.md`, `METRICS_REGISTRY.md` (Article 16 row, per §7) and
   `RPC_REGISTRY.md` (the v3 engine entry) **in the same atomic unit** as the migration.
2. Cody review at apply time regardless of this ADR - this is design signoff, not a pre-approval of
   whatever SQL eventually gets written.
3. A golden assertion that **`pod_refill_plan` row count is unchanged across any v3 shadow run.**
   That is the one-line mechanical proof that the shadow cannot touch the live plan, and it belongs
   on every Phase-2 fixture the way the S-08 tripwire (seq 90) rides on every engine-calling fixture.
4. Link this ADR from the migration comment so the next reader finds the reasoning, not just the DDL.
