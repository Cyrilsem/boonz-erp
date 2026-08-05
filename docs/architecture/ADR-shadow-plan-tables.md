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

---

## 9. Addendum — the sibling shadow table landed at P2, not P3.1 (relay leg 24, 2026-07-30)

§2 granted "whatever sibling shadow tables Phase 2/3 need on identical terms (`pod_refills_shadow`
**if the stitch ladder needs a shadow line table at P3.1**)". That timing prediction was wrong, and
the reason is worth recording because it was invisible until the acceptance assertions were read
column by column.

**What was measured (leg 24, before any SQL was written).** Every one of the seven gated Phase-2
acceptance assertions reads `public.pod_refills` or `public.blocked_demand` — never
`pod_refill_plan`. Fixture 14 seq 31 asserts `pr.current_stock <= pr.max_stock`; seq 32 asserts
`pr.qty = 0 AND pr.clamp_reason IS NOT NULL`; fixture 3 seq 1 and fixture 14 seq 30 are `NOT EXISTS`
coverage probes on `pod_refills`; fixture 105 seq 10 counts `blocked_demand` rows. **None of those
four columns exists in `pod_refill_plan_shadow`**, because that table mirrors the plan/approval grain.

So the Phase-2 acceptance contract was unsatisfiable by the leg-12 scaffold. `engine_add_pod_v3`
could have proven nothing by writing only to `pod_refill_plan_shadow`, and the only alternative —
writing the live `pod_refills` — is precisely what LAW 4 forbids. The sibling is a **P2 prerequisite**,
not a P3.1 convenience. S-19 saw the shape risk and filed it under Phase 3; that filing was the error.

**What landed (4 migrations, `20260730201143` … `20260730201511`):** `public.pod_refills_shadow` on
identical terms (§2's shadow triple, §5's four staleness guarantees hold verbatim), plus
`public.v_blocked_demand_shadow_v3` — a **view**, because `blocked_demand` is derived by a pure
`SELECT` and the shadow rows it reads are already durable and immutable, so Article 14's first clause
genuinely binds there. Table where staleness is real, view where it is not.

**Three things this addendum changes for later readers:**

1. **§7 row 8's hedge is now resolved explicitly.** It read "generic write-audit trigger applies **if
   attached**". It was never attached to `pod_refill_plan_shadow`, and it is deliberately not attached
   to `pod_refills_shadow` either — a non-protected diagnostic object taking ~544 INSERTs per nightly
   run would drown the audit log, and `run_id`/`engine_tag`/`produced_at` already answer "who wrote
   what, when". This is now a **stated decision** on both tables rather than a latent omission.
2. **§5 guarantee (1) now has enforcement behind it.** "Write-once per run, never UPDATEd" is
   load-bearing for the Article 14 signoff, but `CREATE POLICY … FOR UPDATE USING (false)` binds
   `authenticated` only — RLS is bypassed by the SECURITY DEFINER writer and by `service_role`. The
   guarantee was therefore a promise with nothing behind it on `pod_refill_plan_shadow`.
   `pod_refills_shadow` carries a `BEFORE UPDATE OR DELETE` trigger that raises, which **does** bind
   the writer. Proven behaviourally, not asserted: UPDATE and DELETE both refused inside a rollback
   envelope. ⚠️ `pod_refill_plan_shadow` still lacks this — carried as **RISK 74**.
3. **§8 obligation 3 is extended from one live table to three.** The obligation named
   `pod_refill_plan`. At the engine-advisory grain the tables that actually matter are `pod_refills`
   and `blocked_demand`, and `blocked_demand` was untripwired on every Phase-2 fixture. seq 92/93 on
   fixture 2 and seq 97 on fixture 14 close that. Note the two forms differ on purpose: **absolute**
   counts where the fixture calls no engine, **scoped-to-its-own-plan_date** where it legitimately
   calls v19 (fixture 14 seq 93). Collapsing them into one shape would either flake or go vacuous.

**One new constitutional idea worth carrying forward.** `pod_refills_shadow` enforces PRD-110 LAW 5
as a CHECK — `qty > 0 OR clamp_reason IS NOT NULL` — so a silent zero is refused by the database
rather than caught by a fixture. This was safe to impose because it was measured first: across all
3,841 live `pod_refills` rows, 834 have `qty = 0` and **zero** of those have a NULL `clamp_reason`.
Two sibling CHECKs do the same for availability (`boonz_wh` must state its number; `unknown` must
explain itself). Where a law can be made unrepresentable, prefer that to asserting it.

---

## 10. Addendum — WMAPE telemetry is a SNAPSHOT, not a view (relay leg 52, 2026-07-31)

§2 closes with: _"The nightly diff (v3 shadow vs v19 live) is a **VIEW** over this table joined to
`pod_refill_plan`, not a second materialization. **WMAPE telemetry likewise.**"_

The diff half held to that and shipped as three views at leg 51 (`v_engine_diff_v3*`). **The WMAPE
half cannot, and this addendum records why, with the measurement that changed the answer.**

### 10.1 The evidence §2 did not have

WMAPE needs **actuals**, which the diff does not. Actuals resolve through
`public.v_sales_history_resolved`, which derives `pod_product_id` from `sales_history.pod_product_name`
by a **correlated name lookup** (`pod_products`, falling back to `product_name_conventions`). Measured
live this leg with `EXPLAIN (ANALYZE)`:

| Shape                                               | Cost       | Why                                                                 |
| --------------------------------------------------- | ---------- | ------------------------------------------------------------------- |
| WMAPE over all plan_dates, LATERAL per plan line    | **62.7 s** | name-resolution subplan executed **513,435** times                  |
| Same, pre-aggregating sales once then range-joining | **13.3 s** | resolution now once per sales row — but still the whole 38,467 rows |
| `sales_daily` aggregate **alone**, nothing else     | **13.5 s** | the floor: the actuals source itself costs this to scan             |
| **One plan_date, date-bounded window**              | **2.75 s** | the shape this addendum authorises                                  |

The 13.5 s row is the load-bearing one: **it is a floor, not an implementation detail.** Any live view
computing WMAPE across dates pays it on **every read**, and RISK 88 already binds on this class of
object. There is no index that removes it, because the join key is computed by a per-row lookup.

### 10.2 The second, independent reason — measurement provenance

A live view **recomputes history on every read**. Sales restatements, late deliveries and
name-mapping corrections would silently rewrite a WMAPE that CS has already reviewed, mid-gate. The
Phase-2 GATE is _"2 weeks shadow; WMAPE(v3) ≤ WMAPE(v19)"_ — a claim about a **measurement taken at a
point in time**. It must be recorded, with `measured_at`, not re-derived. This is the same failure
family as RISK 102: an object that quietly changes what it said, with nothing announcing the change.

### 10.3 Decision

`public.engine_forecast_error_v3` is a **measurement snapshot**, written per `plan_date` by
`public.refresh_engine_forecast_error_v3(date)`. Article 14's real test is **silent** staleness
(see the Cody cheat-sheet correction of 2026-07-30), and every guarantee against it is explicit here:

1. **Refresh semantics are named and idempotent** — DELETE + INSERT scoped to one `plan_date`;
   re-measuring is safe and is fixture-pinned (fixture 36 seq 30).
2. **Every row carries `measured_at`** — the snapshot always says when it was taken.
3. **`actuals_settled`** marks whether the horizon had elapsed at measurement time. A row measured
   early is visibly provisional rather than quietly wrong.
4. **Staleness cannot masquerade as a score** — `v_engine_wmape_v3.wmape` is NULL and `is_vacuous`
   is TRUE with a named `vacuous_reason` whenever there is nothing to measure (RISK 102 idiom,
   fixture 36 seq 23-29).

The **grain is `(plan_date, engine_tag, machine_id, pod_product_id)`, NOT shelf** — actuals only
resolve at machine x pod, and 139 real (plan_date, machine, pod) groups span more than one shelf, so
a shelf grain would double-count their sales. The PK makes that structurally impossible.

The two reader objects (`v_engine_wmape_v3`, `v_engine_wmape_v3_gate`) remain **VIEWS** over the
snapshot, so §2's intent — do not materialize the same answer twice — is preserved for everything
that can be derived cheaply.

### 10.4 What is NOT amended

§2 still governs the **diff**: `v_engine_diff_v3*` stay views and must not be materialized. This
addendum is scoped to WMAPE telemetry and to the actuals-cost argument above. Any future
materialization needs its own addendum and its own measurement.

---

## 11. Addendum — "on identical terms" has to mean REVOKE, not GRANT (relay leg 54, 2026-07-31)

§2 admitted sibling shadow tables "on identical terms (`pod_refills_shadow` …)". Leg 54 found that
**two of the three siblings did not in fact land on those terms**, and that the reason is a Postgres
behaviour worth writing into the ADR so no future sibling repeats it.

### 11.1 What was found

`engine_forecast_error_v3` and `shadow_runner_log_v3` both granted `authenticated`
INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER. `pod_refills_shadow`, the reference sibling,
grants **SELECT only**. Leg 53's own record asserted that `shadow_runner_log_v3` "deliberately
follows the `pod_refills_shadow` standard" — the migration did contain `GRANT SELECT`, and that was
read as evidence.

### 11.2 The mechanism

⛔ **A `GRANT` is additive. It cannot narrow anything.** Supabase's default privileges on `public`
have _already_ granted ALL to `authenticated` by the time a `CREATE TABLE` returns, so writing
`GRANT SELECT ON <new table> TO authenticated` is a **no-op that reads like a lockdown**.
`pod_refills_shadow` is SELECT-only because something explicitly **REVOKED**; the others were never
revoked. Neither table was exploitable — RLS was enabled with SELECT-only policies, so the DML paths
were refused anyway — but the ADR's whole point is that shadow tables do not lean on a single line
of defence.

### 11.3 The obligation this adds to §8

Any future shadow/telemetry sibling **must issue an explicit `REVOKE` of the non-SELECT privileges**
and must **read the privilege state back** in the same migration (or in a golden assertion). The
statement is not the state.

⚠️ **And the assertion must name the role that actually has the grant.** Fixture 36 seq 31 and
fixture 37 seq 26/27 all checked **`anon`** — which correctly held nothing — and so passed while
`authenticated` held everything. Fixture 37 seq **28/29/30** now pin `authenticated` on both tables,
with a non-vacuity check that SELECT survived the revoke.

📌 Closed by `20260731121100`. `blocked_demand` carries the same loose grants and is knowingly left
for a later leg — it is not a shadow table and its writers want their own review first.

---

## 7. Sibling created under §2 — `refill_plan_output_shadow` (PRD-110 P3.1c, 2026-07-31)

§2 pre-authorized "whatever sibling shadow tables Phase 2/3 need on identical terms
(`pod_refills_shadow` if the stitch ladder needs a shadow line table at P3.1)". P3.1c needed one at
**SKU grain**, which neither existing shadow provides: `pod_refills_shadow` and
`pod_refill_plan_shadow` are both pod-grain, and stitch's entire job is pod → boonz SKU.

`refill_plan_output_shadow` (migration `20260731173118`) shadows `refill_plan_output`, carries the
§2 triplet (`run_id`, `engine_tag`, `produced_at`) plus `source_run_id` naming the
`pod_refills_shadow` run it was stitched from, and is written only by `stitch_v3`. The §3 argument
transfers unchanged — the ladder resolves against warehouse stock as it was at run time, and the
Phase 3 gate is longitudinal.

**Two corrections to how §5.1 had been implemented, both binding on the next sibling:**

1. ⛔ **Append-only must be a TRIGGER, not RLS.** RLS `USING (false)` does not bind the table
   owner, `service_role`, or a `SECURITY DEFINER` body — which is exactly how the engine writes.
   `pod_refills_shadow` got this right (`tg_pod_refills_shadow_append_only`);
   `pod_refill_plan_shadow` pins UPDATE/DELETE with RLS policies **only**, so its §5.1 guarantee
   is weaker than this document claims. Recorded here rather than fixed, since nothing writes it.
2. ⛔ **TRUNCATE defeats both.** It is not a row operation: it bypasses RLS and fires no
   `FOR EACH ROW` trigger. §5.1's "write-once, never updated" is only true once `TRUNCATE` is
   revoked from `authenticated` — see **S-88** in `MIGRATIONS_REGISTRY.md`.

§5.4 retention (90 days, manual logged purge) applies. Growth is ~3 rows per golden-fixture-44
execution, which is the intended ledger behaviour, not a leak.

---

## Addendum — `plan_edits_v3` and the `compose_v3` run tag (PRD-110 P3.6, leg 70)

`plan_edits_v3` joins this family as an **append-only event ledger** of human plan edits. Under
Article 14 as stated precisely, it is permitted without ADR signoff for materialisation: it holds
state no view can derive (who decided what, when, and against which base), not a cached query result.

Two notes against the numbered warnings above:

1. ⭐ **Note 2's TRUNCATE gap is closed here, and only here.** `plan_edits_v3` carries a
   statement-level `BEFORE TRUNCATE` trigger in addition to the row-level UPDATE/DELETE guard, so its
   append-only claim holds against the one operation that bypasses both RLS and row triggers.
   `pod_refills_shadow`, `refill_plan_output_shadow` and `pod_refill_plan_shadow` still do not.
2. ⛔ **`pod_refills_shadow` now carries two kinds of run.** `engine_add_pod_v3` writes base runs;
   `compose_plan_with_edits_v3` writes `engine_tag='compose_v3'` overlay runs into the same table.
   Any consumer that means "the engine's own output" must filter `engine_tag <> 'compose_v3'`, or it
   will read an overlaid plan as if the engine had produced it. Both P3.6 functions do this; a future
   reader that forgets is the obvious next defect.

§5.4 retention (90 days, manual logged purge) applies to both.

---

## Addendum — `pipeline_runs_v3`, and the ordering tie it exists to defeat (PRD-110 P3.7, leg 71)

`pipeline_runs_v3` joins this family as the **receipt** for one `engine → compose → stitch` run.
Cody reviewed it under Article 14 and required this entry as the signoff.

**Why a view could not do this.** The obvious objection is that the chain is already recoverable:
`refill_plan_output_shadow.source_run_id` names the `pod_refills_shadow` run stitch consumed, and a
`compose_v3` row's `reasoning->compose_v3->base_run_id` names the base it overlaid. That recovers
what _happened_. It does not record what the pipeline _intended_ (a run that failed at compose
leaves no stitch row to point back at anything), which stage failed and how long each took, or —
decisively — **which plan CS stands behind**. Approval is state no view can derive.

**The defect this closes, measured on 2026-07-31.** `stitch_v3` called with a NULL source resolves
its input by `ORDER BY produced_at DESC, run_id DESC`. `pod_refills_shadow.produced_at` DEFAULTs to
`now()`, which is the **transaction** timestamp — so a base run and the run composed from it inside
one transaction (which is exactly what a pipeline is) **tie**, and the tie-break falls to uuid
ordering of `run_id`. Whether the human's overlay reached the stitched plan was therefore decided by
a coin flip. Leg 70's pointer recorded the coupling as "probably the desired pipeline"; it was
neither desired nor a pipeline. `run_pipeline_v3` passes every run id **explicitly** and re-asserts
after the fact that `stitch.source_run_id` is the run it planned. Golden fixture 51 forces the coin
flip to its wrong face — the base run is minted with a `run_id` that sorts above every random v4
uuid — and proves the pipeline is unaffected.

**Against the numbered warnings above:**

1. ⭐ **Note 1 and Note 2 are both satisfied from birth.** `pipeline_runs_v3` carries a row-level
   `BEFORE UPDATE OR DELETE` trigger _and_ a statement-level `BEFORE TRUNCATE` trigger. It is the
   second member of the family (after `plan_edits_v3`) whose append-only claim survives TRUNCATE.
   `pod_refills_shadow`, `refill_plan_output_shadow` and `pod_refill_plan_shadow` still do not.
2. ⭐ **The approval dimension is the only mutable one, and it is one-way.** The trigger freezes
   every other column at insert, refuses to clear or rewrite an approval once granted, and refuses
   to un-retire a retired one. `ux_pipeline_runs_v3_standing_approval` (partial unique on
   `plan_date WHERE approved_at IS NOT NULL AND approval_superseded_at IS NULL`) makes "one standing
   approval per night" structural rather than writer discipline.
3. ⚠️ **Article 5, stated rather than hidden.** The trigger does not require that an approval arrive
   via `approve_pipeline_run_v3`, because the `app.rpc_name` GUC leaks across statements in this
   database (PRD-016B) and a trigger that trusted it would be worse than one that does not. What
   holds instead is the S-88 guarantee the whole family rests on: `authenticated` holds `SELECT`
   only and `anon` holds nothing, so no application user can approve outside the RPC.

**LAW 4 boundary.** An approval recorded here has **no live effect**. Nothing in P3.7 reads or
writes `refill_plan_output`, `pod_refills`, `dispatch_lines` or `machines_to_visit`; the live
cutover is a parked CS flag (D-34). §5.4 retention (90 days, manual logged purge) applies.

---

## ADR addendum — `scoreboard_daily_v3` (PRD-110 P4.5, leg 101)

**Article 14 signoff.** Article 14 requires an ADR for a table that materialises a query result, and
the real test is **silent staleness**, not the name. `scoreboard_daily_v3` is accepted for two
reasons, and the first is the load-bearing one.

1. ⭐ **A view provably cannot recompute it.** Two of the nine metrics read present-tense sources that
   keep no history: `shelf_composition` (no history at all) and, at slot grain, the day's final WEIMI
   state. Once a day passes, the inputs for `composition_confidence_avg` are **gone**. A view over
   today's tables asked for last Tuesday would answer with today's numbers and look right. That is
   the staleness Article 14 exists to prevent — here the **table** is the fix, not the risk.
2. **Refresh semantics are explicit and checkable.** Idempotent upsert keyed
   `(metric_date, scope_kind, scope_ref, metric_key, engine_tag) NULLS NOT DISTINCT`; every row
   carries `computed_at` and `computed_by`; cron 47 runs at 02:45 Dubai for the day that just closed;
   `v_scoreboard_health_v3` exposes `days_in_latest_streak` so a stalled job is visible as a number
   rather than as quietly old rows. Fixture 65 seq 4 pins idempotency, seq 24 the streak.

**Staleness cannot be silent here.** The failure mode Article 14 names is a snapshot that keeps
serving old numbers as if fresh. This table cannot: a missing day is a **missing row**, not a stale
one, and the health view reports the gap directly.

⛔ **Scope boundary — wave 1 populates `scope_kind = 'fleet'` ONLY.** `'venue_group'` and `'machine'`
are forward-declared in the CHECK so the grain can widen without a type change, but the writer emits
neither. **Phase 5's per-cluster cutover comparison needs `venue_group` and it is NOT built** — see
PARKING-LOT **S-175**. Do not read the presence of the enum value as the presence of the data.

**LAW 4 boundary.** The scoreboard is measurement only. Nothing here writes `refill_plan_output`,
`pod_refills`, `dispatch_lines` or `machines_to_visit`, and no engine reads it; it observes the
shadow run rather than participating in it. Live cutover remains a parked CS flag.
