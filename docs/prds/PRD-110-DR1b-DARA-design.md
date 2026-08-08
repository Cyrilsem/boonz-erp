# PRD-110 DR-1b — DARA DESIGN · machine-scope the ADD engine + branch the write path

Leg 161 · 2026-08-08 · ships FLAG-OFF (0 of 10 clusters authoritative)
Predecessor: PRD-110-DR1-DARA-cutover-design.md (DR-1, executed leg 160)

---

## Design problem

DR-1 shipped the cutover _authority_ (`engine_cutover_authority_v3`), the _gate_
(`v_cutover_readiness_v3`), the _verbs_ (`flip_cluster_to_v3_v3` / `revert_cluster_to_v19_v3`)
and a _guard_ in `_build_draft_core_v3`. But the guard's only move is to HALT: while any cluster
is authoritative for v3, the nightly builder returns `refused_cutover_not_implemented` and the
WHOLE fleet goes unplanned. That is correct-and-loud, and it is useless as a cutover.

Three defects make a partial cutover physically impossible today. All three are in the ADD path:

1. **`engine_add_pod` line 90 wipes the whole date.**
   `DELETE FROM public.pod_refills WHERE plan_date = p_plan_date;` — unscoped. Even if v3 wrote
   correct rows for a flipped cluster, v19's next run deletes them. ⛔ **This, not the SELECT
   scope, is the binding blocker.** The parking lot recorded the blocker as "both ADD engines are
   whole-plan-date scoped", which is true of the _read_; the _unscoped DELETE_ is what actually
   makes the two engines unable to coexist on one plan_date.
2. **`engine_add_pod`'s `picked` CTE takes every picked machine**, regardless of authority.
3. **There is no path from `pod_refills_shadow` into `pod_refills`.** `engine_add_pod_v3` writes
   exactly one table — `pod_refills_shadow` (its only INSERT, line 428) — so a flipped cluster
   has nowhere for its plan to land.

**The invariant to protect:** for a given `plan_date`, every row in `pod_refills` is authored by
exactly ONE engine, and the partition of machines between engines is a total function of
cluster authority. No machine planned twice; no machine planned zero times.

## Proposed schema

No new tables. No column changes. DR-1b is a **scoping** change: one new canonical view, one new
RPC, and scope predicates threaded into two existing bodies. D1/D2/D3/D7 are not engaged.

### Object 1 (NEW, canonical — Article 16) — `v_add_engine_scope_v3`

The single object that answers "which engine owns this machine tonight". Both engines and the
promotion RPC read it; none of them restates the rule.

```sql
CREATE OR REPLACE VIEW public.v_add_engine_scope_v3 AS
SELECT mtv.plan_date,
       mtv.machine_id,
       mtv.official_name,
       m.venue_group AS cluster_key,
       CASE WHEN a.authoritative_engine = 'v3' THEN 'v3' ELSE 'v19' END AS assigned_engine
  FROM public.machines_to_visit mtv
  JOIN public.machines m ON m.machine_id = mtv.machine_id
  LEFT JOIN public.engine_cutover_authority_v3 a ON a.cluster_key = m.venue_group
 WHERE mtv.status IN ('picked','cs_added');
```

⭐ **`LEFT JOIN` + `CASE`, never `JOIN` + `=`.** A machine whose `venue_group` has no authority
row (a new venue group added between flips) must FALL BACK TO v19, not vanish from both engines.
An inner join here would silently drop it from the plan — the LAW 5 silent-qty-0 class, at
machine grain. D2 in spirit: the absence of a row is a _state_, and it is spelled `v19`.

### Object 2 (AMEND) — `engine_add_pod`, two scope predicates

```sql
-- was: DELETE FROM public.pod_refills WHERE plan_date = p_plan_date;
DELETE FROM public.pod_refills pr
 WHERE pr.plan_date = p_plan_date
   AND NOT public.is_cluster_authoritative_v3(pr.machine_id);
```

and in the `picked` CTE:

```sql
   AND NOT public.is_cluster_authoritative_v3(mtv.machine_id)
```

`is_cluster_authoritative_v3(uuid)` already exists (DR-1, STABLE, machine-grain). Reusing it
rather than re-deriving `venue_group = cluster_key` is the Article 16 point.

### Object 3 (NEW) — `promote_v3_shadow_to_live_v3(p_plan_date date) RETURNS jsonb`

SECURITY DEFINER. Copies the **latest** `engine_add_pod_v3` shadow run for `p_plan_date` into
`pod_refills`, **for authoritative machines only**.

- ⛔ **Must pin ONE `run_id`.** `pod_refills_shadow` PK is
  `(run_id, plan_date, machine_id, shelf_id, pod_product_id)` while `pod_refills` PK is
  `(plan_date, machine_id, shelf_id, pod_product_id)`. Promoting "all shadow rows for the date"
  would collide on the live PK the moment a second shadow run exists. Select
  `run_id` by `MAX(produced_at)` where `engine_tag = 'engine_add_pod_v3'`.
- DELETE-then-INSERT within the authoritative scope, so a machine that dropped a shelf between
  runs cannot keep a stale live row.
- **Column bridge:** `pod_refills_shadow.velocity_instock` → `pod_refills.velocity_30d`. This is
  the only non-identity mapping; every other live column exists in shadow by the same name.
  ⚠️ **This does NOT decide D-27 half-2** (`velocity_raw` vs the canonical in-stock object, an
  open CS ask). It records _the number v3 actually sized with_ in the column the live table
  reserves for exactly that. If D-27h2 later renames the concept, this mapping moves with it.
- **Refuses loudly** (RAISE) when authoritative machines are picked but the date has no
  `engine_add_pod_v3` shadow run. Publishing an empty plan for a flipped cluster is worse than
  halting; the halt is recoverable by `revert_cluster_to_v19_v3`.
- Writes one `engine_cutover_audit_v3` row (`action='promote'`) carrying the promoted `run_id`,
  row counts and machine counts — so "which engine planned VOX on Aug 18" is answerable forever.

### Object 4 (AMEND) — `_build_draft_core_v3`, replace the halt with the branch

```
v_add := engine_add_pod(p_plan_date, 14);              -- v19, now scoped to non-authoritative
IF <any cluster authoritative> THEN
  v_add_v3 := engine_add_pod_v3(p_plan_date, 14);      -- shadow, ALL machines (evidence base)
  v_promo  := promote_v3_shadow_to_live_v3(p_plan_date);
END IF;
v_swap  := engine_swap_pod(p_plan_date, 2, 0.30, 14);
v_final := engine_finalize_pod(p_plan_date);
```

⭐ **v3 keeps shadow-planning ALL clusters, not just flipped ones.** Scoping the v3 _read_ to
authoritative machines would be the obvious symmetry and it would be a disaster: with 0 clusters
flipped, v3 would plan nothing, `engine_forecast_error_v3` would stop accruing, and the readiness
gate would never be able to clear a single cluster. The cutover would deadlock on its own
evidence. **v3's SHADOW scope is the fleet; v3's LIVE scope is the flipped clusters.** That
asymmetry IS the design.

## Indexes

None. Every new access path is keyed by existing PKs/indexes:
`pod_refills(plan_date, machine_id, …)` PK serves the scoped DELETE; the shadow PK's leading
`run_id` serves the pinned-run read. D5: no index is proposed because no new query shape lacks one.

## RLS policies

None new. `v_add_engine_scope_v3` is a view over already-policied tables and inherits their
posture. ⛔ **S-308 applies to nothing here** — no new TABLE is created, so the Supabase default
privilege that grants `authenticated` INSERT/UPDATE/DELETE on new `public` tables is not engaged.
The new RPC is SECURITY DEFINER with the `operator_admin`/`superadmin` check the sibling cutover
verbs already use.

## Tradeoffs and alternatives

**Rejected — add `p_machine_ids uuid[]` to the ADD engines.** The obvious "machine-scope the
engine" reading. Rejected on three counts: (a) `engine_add_pod` already carries
`pronargdefaults = 2`, and `engine_add_pod_v3`'s own body carries the comment _"the function is
two-arg with a default; passing p_machine_ids would change its behaviour — the pronargdefaults
trap"_, i.e. a previous leg already walked into this; (b) it creates an overload foot-gun the
project has an explicit standing rule against (`repurpose_machine` precedent); (c) it pushes the
authority rule OUT to every caller, so the next caller that forgets the argument silently plans
the whole fleet. The authority predicate belongs INSIDE the engine, read from one object.

**Rejected — teach `engine_finalize_pod` to merge two sources.** Would leave `pod_refills` itself
incoherent (half the date missing) and every other reader of that table wrong. Promoting into the
canonical table keeps ONE truth for "tonight's plan".

**Rejected — make the promotion a trigger on `pod_refills_shadow`.** D6 says audit by trigger, but
this is not an audit — it is a publish, and it must be ordered relative to v19's DELETE. A trigger
would fire during cron 45's shadow run at 21:22 UTC and publish a plan nobody asked to build.

## ⛔ Named residual — NOT fixed by DR-1b, and CS must know before flipping

**`engine_swap_pod` is still fleet-wide v19, and `swaps_enabled` is `true` globally** (verified
live this leg; a prior memory note claiming `false` is STALE). It writes `pod_swaps`, a different
table from `pod_refills`, so it does not corrupt DR-1b's partition — but `engine_finalize_pod`
merges both into the live plan. **A flipped cluster therefore gets v3 refill lines and v19 swap
lines.** Scoping the SWAP engine is a separate unit against a separate engine, and PRD-110's
Wave-2 SWAP items are all parked under the engine-freeze. Widening DR-1b to cover it would be
LAW 10 scope drift. Instead DR-1b makes it _visible_: the promotion's audit payload and the flip
verb's return both state that swap lines remain v19-authored. Raised as **S-312**.

## Cody handoff checklist

- **Article 2 / 3** — RLS + role gating on the new SECURITY DEFINER RPC (matches sibling verbs).
- **Article 4** — versioned addition; `_v3` suffix; no destructive change to any existing object.
- **Article 5** — the promotion is a state publish; must be idempotent and must refuse rather than
  publish an empty plan.
- **Article 12** — LAW 12: `_assert_refill_plan_writable` still fires; no live plan table is
  touched for a date with non-pending `refill_plan_output` rows.
- **Article 14** — append-only audit: `engine_cutover_audit_v3` gains a `promote` action.
- **Article 16** — canonical objects: `v_add_engine_scope_v3` and `is_cluster_authoritative_v3`
  are the ONLY places the authority rule is stated. No engine restates it.
- ⭐ **The flag-off proof Cody should demand:** with 0 clusters authoritative,
  `is_cluster_authoritative_v3` is false for every machine, so the scoped DELETE degenerates to
  the unscoped one, the `picked` CTE is unchanged, the `IF` in `_build_draft_core_v3` is never
  taken, and `promote_v3_shadow_to_live_v3` is never called. **Behaviour must be byte-identical —
  and that is testable as a whole-table md5 of `pod_refills` across the change.**
