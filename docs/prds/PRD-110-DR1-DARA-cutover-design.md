# PRD-110 DR-1 · DARA DESIGN — per-cluster live-engine cutover authority (Phase 5)

Design date 2026-08-08 (leg 160). Ships FLAG-OFF. LAW 4 holds: this loop never flips it.

---

## Design problem

v3 is complete and runs nightly in shadow. CS ruled (2026-08-04) that the cutover be built with
**per-cluster** granularity, that CS picks the first cluster at flip time (~Aug 17-19), and that the
unit ship flag-off. The unit must make a flip **auditable**, **reversible per cluster**, and must
**refuse to flip a cluster while that cluster's v3 WMAPE is vacuous**.

The entity being modelled is _which engine is authoritative for a cluster of machines_, plus the
evidence that justifies changing it. The invariant it protects: **no cluster is ever believed to be
planned by v3 while v19 is silently the thing that planned it.**

### ⛔⛔ THE FOOT-GUN THAT DECIDES THE WHOLE SHAPE — probed, not assumed

`_build_draft_core_v3`'s v19 pipeline is exactly three calls:

```
v_add   := engine_add_pod(p_plan_date, 14);
v_swap  := engine_swap_pod(p_plan_date, 2, 0.30, 14);
v_final := engine_finalize_pod(p_plan_date);
```

**Both ADD engines are whole-plan-date scoped, not machine scoped:**
`engine_add_pod(p_plan_date date, p_days_cover integer)` and
`engine_add_pod_v3(p_plan_date date, p_days_cover integer)`. Only `engine_finalize_pod` has a
machine-scoped overload (`p_machine_ids uuid[]`).

⛔ **Therefore a per-cluster cutover CANNOT be implemented as a branch at that call site.** There is
no argument to hand either engine that says "only these machines". Splitting the plan per cluster
requires machine-scoping the ADD engine — a separate, substantial unit against the most protected
production path in the system. **That work is DR-1b and is deliberately NOT in this unit.**

This is why the design below is _authority + gate + a loud refusal_, not a write-path branch.

---

## Proposed schema

### Table 1 — the registry (one row per cluster)

```sql
CREATE TABLE IF NOT EXISTS public.engine_cutover_authority_v3 (
  cluster_key           text PRIMARY KEY,                    -- machines.venue_group
  authoritative_engine  text        NOT NULL DEFAULT 'v19'
                          CHECK (authoritative_engine IN ('v19','v3')),
  flipped_at            timestamptz,                         -- NULL while never flipped
  flipped_by            uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  flip_reason           text,
  flip_evidence         jsonb,                               -- readiness snapshot AT flip time
  n_machines_at_flip    integer,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  CONSTRAINT eca_v3_flip_fields_together CHECK (
    (authoritative_engine = 'v19' AND flipped_at IS NULL)
    OR (authoritative_engine = 'v3' AND flipped_at IS NOT NULL
        AND flip_reason IS NOT NULL AND flip_evidence IS NOT NULL)
  )
);
```

⭐ **The CHECK is the anti-theatre guard**: a row cannot sit in `'v3'` without carrying the timestamp,
the human reason, and the evidence snapshot that justified it. There is no way to flip quietly.

**Seed = the 10 ACTIVE venue groups, all `'v19'`.** ⛔ `'WH'` is EXCLUDED by predicate, not by
hand-listing: it is the warehouse, not a venue, and it appears only on Inactive machines. Seeding
`SELECT DISTINCT venue_group FROM machines WHERE status='Active'` yields exactly the 10 real clusters
and never WH. (D2: `authoritative_engine` NOT NULL — "unknown authority" is not a state we allow.)

### Table 2 — append-only audit, INCLUDING refusals

```sql
CREATE TABLE IF NOT EXISTS public.engine_cutover_audit_v3 (
  audit_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_key   text        NOT NULL,
  action        text        NOT NULL CHECK (action IN ('flip_to_v3','revert_to_v19')),
  outcome       text        NOT NULL CHECK (outcome IN ('applied','refused')),
  refusal_code  text,                                        -- NULL iff outcome='applied'
  from_engine   text,
  to_engine     text,
  reason        text        NOT NULL CHECK (length(btrim(reason)) >= 10),
  evidence      jsonb       NOT NULL,                        -- readiness row at decision time
  actor         uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  actor_role    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT eca_audit_refusal_code_iff_refused CHECK (
    (outcome = 'refused'  AND refusal_code IS NOT NULL) OR
    (outcome = 'applied'  AND refusal_code IS NULL))
);
```

⭐ **A REFUSED flip is logged too.** "Auditable" that records only successes would hide the far more
interesting fact — that CS tried to flip VOX on Aug 17 and the gate said no. The 10-char `reason`
floor matches the house idiom already used by the `pod_inventory_edit` RPCs.

### Indexes

```sql
CREATE INDEX IF NOT EXISTS idx_eca_audit_cluster_created
  ON public.engine_cutover_audit_v3 (cluster_key, created_at DESC);
-- Serves: "show me this cluster's flip history", the only read path the FE/CS will use.

CREATE INDEX IF NOT EXISTS idx_eca_authority_v3_live
  ON public.engine_cutover_authority_v3 (cluster_key)
  WHERE authoritative_engine = 'v3';
-- Partial, and it will be EMPTY on apply. Serves the hot read: "is anything live on v3 tonight?"
-- asked once per nightly build. D5: the index exists for that query, not for the table.
```

### RLS posture — matches the live v3-table idiom exactly

Probed on `facing_proposals_v3` / `feedback_ledger_v3`: RLS enabled, a single SELECT policy
`USING (true)` to `authenticated`, and **no INSERT/UPDATE/DELETE policies at all** — writes arrive
only through SECURITY DEFINER RPCs. Both new tables follow that shape; the audit table additionally
gets explicit `USING (false)` UPDATE/DELETE policies so append-only is stated, not merely implied.

⛔ Do NOT grant `anon` anything on either table (S-268: name `anon` explicitly and prove it holds
nothing).

---

## The gate view — `v_cutover_readiness_v3`

Per-cluster, one row per **active** cluster, aggregating `engine_forecast_error_v3` at machine grain
and joining `machines.venue_group`.

⭐ **THE INSIGHT THAT UNBLOCKS PER-CLUSTER TODAY.** The parking lot records (S-175) that per-cluster
comparison "cannot be made" because `scoreboard_daily_v3.scope_kind` is `'fleet'` only. **That is
true of the scoreboard and irrelevant to this gate.** `engine_forecast_error_v3` carries `machine_id`
and joins to `machines` with **zero unjoined rows** (probed), so the gate aggregates the error table
directly and needs no S-175 writer pass. The scoreboard stays fleet-grain; the gate does not use it.

Columns: `cluster_key`, `n_machines_active`, `is_registered`, `authoritative_engine`,
`last_v3_plan_date`, `n_series_v3`, `n_settled_v3`, `n_series_v19`, `n_settled_v19`,
`wmape_v3`, `wmape_v19`, `wmape_delta`, `bias_v3`, `bias_v19`, `is_vacuous`, `refusal_code`,
`verdict`.

WMAPE is computed the same way `v_engine_wmape_v3` computes it — `sum(abs_error)/sum(actual_units)`
over settled series only, NULL when there are no settled series or the denominator is zero. ⛔ **It
is never coerced to 0 (S-176):** a fabricated zero would sign a cutover off on no evidence.

### Refusal taxonomy (ordered — first match wins)

| code                      | meaning                                                | clusters today |
| ------------------------- | ------------------------------------------------------ | -------------- |
| `cluster_not_registered`  | live cluster with no registry row (a cluster appeared) | 0              |
| `cluster_not_live`        | registry row whose cluster has no Active machines      | 0              |
| `already_v3`              | flip requested on a cluster already authoritative      | 0              |
| `no_v3_measurement`       | never a single v3 series for this cluster              | **6**          |
| `no_v19_baseline`         | no v19 series to compare against                       | 0              |
| `v3_horizon_not_elapsed`  | v3 series exist, none settled yet                      | **4**          |
| `v3_zero_actuals`         | settled but the denominator is 0                       | 0              |
| `v19_horizon_not_elapsed` | v19 side not settled, so no comparison is possible     | 0              |
| `v3_worse_than_v19`       | both measurable and `wmape_v3 > wmape_v19`             | 0              |
| `ready`                   | both measurable and `wmape_v3 <= wmape_v19`            | **0**          |

⚠️ **All 10 clusters refuse today, and they refuse for two different reasons.** Six
(ADDMIND, GRIT, LVLUP, VML, VOX, WPP) have **never** had a v3 series — VOX is the largest cluster in
the fleet at 11 machines. The other four (AMAZON, INDEPENDENT, NOVO, OHMYDESK) have exactly one
plan_date of v3 series (2026-08-04) with **zero settled**, horizon settling **2026-08-11**.

---

## RPC signatures

```sql
flip_cluster_to_v3_v3(p_cluster_key text, p_reason text) RETURNS jsonb
revert_cluster_to_v19_v3(p_cluster_key text, p_reason text) RETURNS jsonb
is_cluster_authoritative_v3(p_machine_id uuid) RETURNS boolean
```

- **`flip_cluster_to_v3_v3`** — evidence-gated. Reads `v_cutover_readiness_v3` for the cluster,
  refuses on anything but `ready`, and **writes an audit row either way**. Role-gated to
  `operator_admin` / `superadmin`, mirroring `_build_draft_core_v3`'s own gate verbatim.
- **`revert_cluster_to_v19_v3`** — ⭐ **NEVER evidence-gated.** A rollback blocked by the same gate
  that blocks the forward path is not a rollback. It requires only the role and a reason. This is
  the design rule I care most about in this proposal: **the safety valve must not be able to jam.**
- **`is_cluster_authoritative_v3(machine_id)`** — the read-side predicate Phase 5's write path will
  consult. STABLE, returns `false` for every machine on apply.

⚠️ Live `user_profiles.role` values are only `field_staff`, `operator_admin`, `warehouse`.
**`superadmin` and `manager` have zero live members** — naming them is forward-compatibility, and
`operator_admin` is the role that will actually flip.

---

## How far to wire the read side THIS leg — the recommendation

**Wire two consumers. Park the third.**

1. ✅ **`run_nightly_shadow_v3` records the authority state nightly.** Its log `detail` gains the
   authoritative-cluster list and the readiness verdict counts. Real consumer, provably inert, and it
   accumulates the operational record CS reads on Aug 17.
2. ✅ **`_build_draft_core_v3` REFUSES to build when any cluster is authoritative for v3.** Because
   the ADD engines are date-scoped (the foot-gun above), the live builder physically cannot honour a
   partial cutover. Its only honest options are to _lie_ (plan those machines with v19 while CS
   believes they are on v3) or to _stop loudly_. It stops loudly, returning
   `status = 'refused_cutover_not_implemented'` naming the clusters.
3. ⏸️ **PARKED — DR-1b: machine-scope the ADD engine and branch the write path.** That is the real
   cutover and it is its own Dara design + Cody review + fixture.

⭐ **Why this is not theatre (S-138) and not a switch we would be tempted to throw (LAW 4).** The flag
does something real and immediate — it changes what the nightly builder does — but what it does is
_halt with a named reason_, never _silently plan with the wrong brain_. It is the house doctrine of
S-304a applied ahead of time: the sensor that would have said `ok` is built to say the true thing
instead. And the gate makes flipping impossible today regardless, since all 10 clusters refuse.

⛔ **State the blast radius plainly, because it is large:** flipping a cluster stops the ENTIRE
nightly plan, not that cluster's share of it. That is intentional and it is the conservative
direction, but CS must know it before Aug 17 — and `revert_cluster_to_v19_v3` restores the plan
immediately with no evidence requirement.

---

## Tradeoffs and alternatives

- **Rejected: a per-cluster column on `refill_policy_params`.** It is a single-row table (id=1); a
  per-cluster dial there would mean 10 columns and a migration per new cluster. The registry table is
  the normalized shape (D1/D3).
- **Rejected: `_build_draft_core_v3` warns and plans anyway.** This is the option that produces a
  silent lie, and S-304a is the whole reason the house does not accept it: three sensors said `ok`
  over a night that planned nothing.
- **Rejected: gate on the scoreboard.** It would have forced the S-175 venue_group writer pass first
  and delivered a fleet-grain answer to a per-cluster question. Reading `engine_forecast_error_v3`
  directly is both cheaper and actually per-cluster.
- **Rejected: `machines_to_visit.route_cluster` as the cluster key.** It is a routing artifact that
  varies per plan_date; `venue_group` is a stable property of the machine and is what CS means by
  "cluster" (it is also what the DR-1 ruling's own wording tracks).
- **Considered and kept: evidence snapshot as `jsonb` on both tables.** Denormalized on purpose — the
  justification must survive later changes to the gate view's definition. An evidence claim that
  silently re-computes is not evidence.

---

## Cody handoff checklist

- **Article 2/3** — RLS shape on two new tables; SECURITY DEFINER on three new RPCs; `anon` named
  explicitly and granted nothing.
- **Article 4** — versioned additions only (`*_v3`); nothing destructive; no raw writes to protected
  tables. The unit adds tables and reads; it writes no protected entity.
- **Article 5** — `authoritative_engine` is a status-as-state-machine column with a transition RPC
  per direction, not a raw UPDATE.
- **Article 12** — `_build_draft_core_v3` is touched. Its LAW-12 guard and its Gate-0 behaviour must
  be preserved verbatim; the new refusal must sit where it cannot alter the nightly advisory on a
  flag-off system.
- **Article 14/16** — `RPC_REGISTRY.md` and `METRICS_REGISTRY.md` must move with the new canonical
  objects in the same commit.
- **Appendix A** — recommend `engine_cutover_authority_v3` be ADDED as a protected entity. It decides
  which brain plans the fleet; nothing deserves the label more.
