# PRD-110 · D-40 · DARA DESIGN — the `w_intents` dial

Leg 164 · 2026-08-08 · CS ruling of 2026-08-01: _"ADD THE `w_intents` DIAL as its own Dara/Cody-reviewed unit, with a monotonicity probe proving dial-controls-feature before the miner may map to it."_

---

## Design problem

`active_intent_count` is the second-strongest signal CS gives the picker — 38.2% concordance over
1653 same-day (kept, dropped) pairs, i.e. **61.8% in the inverse direction: CS systematically drops
machines that carry more open intents.** Only `empty_shelves_count` (68.6%) is stronger. The picker's
seven dials (`w_runout`, `w_capacity`, `w_expiry`, `w_stale`, `w_empty`, `w_lowfill`, `w_holes`)
target none of it, so `picker_feature_param_map_v3` carries the feature as a named refusal with
`target_param` NULL — refused **for want of a dial**, not for want of evidence.

This unit gives the signal a dial. It does not turn it on. `w_intents` ships at `0`, which makes the
new term arithmetically inert and every live `p_score` byte-identical — the only way to touch the
canonical priority view inside PRD-110's shadow discipline (LAW 4).

## Proposed schema

```sql
ALTER TABLE public.pick_urgency_params
  ADD COLUMN IF NOT EXISTS w_intents   numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS intents_norm numeric NOT NULL DEFAULT 3;

COMMENT ON COLUMN public.pick_urgency_params.w_intents IS
  'D-40 dial. Weight on s_intents (intent headroom). SHIPPED AT 0 = arithmetically inert; '
  'the live p_score is byte-identical to the pre-D-40 view at this value.';
COMMENT ON COLUMN public.pick_urgency_params.intents_norm IS
  'D-40. Open-intent count at which s_intents saturates to 0 (fully attended).';

ALTER TABLE public.pick_urgency_params
  ADD CONSTRAINT pick_urgency_params_intents_norm_check CHECK (intents_norm > 0),
  ADD CONSTRAINT pick_urgency_params_w_intents_check     CHECK (w_intents >= 0);
```

**Why `w_intents >= 0` and not free-signed.** The measured direction is inverse, and there are two
ways to encode it: a positive weight on an inverted term, or a negative weight on a plain term. Every
existing `s_*` is an **urgency** term (higher = more urgent) carrying a non-negative weight, and the
map already has the idiom for an inverse feature — `fill_pct → w_capacity`, `param_rewards = 'low'`,
`monotonicity −0.458`. Encoding the inversion in the **term** keeps all eight dials the same species.
A negative weight would make `w_intents` the only dial whose sign is load-bearing, and a future
reader summing "weights" would get a number that means nothing.

**Trade: a later CS ruling that intents should RAISE urgency needs a migration to drop the CHECK.**
That is the intended loudness — it is a reversal of a measured direction, not a dial turn.

## The term

Into the `mscore` CTE of `public.v_machine_priority`, alongside the other seven:

```sql
100::numeric * (1::numeric - LEAST(1::numeric,
  COALESCE(
    GREATEST(0::numeric, COALESCE(s_1.active_intent_count, 0)::numeric)
      / NULLIF(p_1.intents_norm, 0::numeric),
    1::numeric)))                                            AS s_intents
```

Reads as **intent headroom**: 100 when nothing is open on the machine (nobody is on it — it needs a
visit), falling to 0 once `intents_norm` intents are open (it is already handled). Range `[0, 100]`,
closed. **Never NULL, never negative, for any value any column can hold.**

Then, at the **five** sites carrying the weighted sum — P1 gate, P2 gate, `p_score`, the
`high_urgency` reason branch, `urgency` — append one term:

```sql
... + p.w_holes * ms.s_holes + p.w_intents * ms.s_intents
```

and expose the term as the **last** output column of the view:

```sql
ms.s_intents::numeric(6,2) AS s_intents
```

## Indexes

None. `pick_urgency_params` is a single row (`CHECK (id = 1)`); `v_machine_priority` is a view over
`v_machine_health_signals`, and the new term adds no join, no scan and no predicate — it is one
arithmetic expression over a column the CTE already selects.

## RLS policies

Unchanged. `pick_urgency_params` already has RLS enabled and this unit adds no table. ⛔ It also adds
no policy: `authenticated=arwdDxtm` on this table is pre-existing and out of scope (LAW 10 — named,
not fixed). S-138's standing pair of assertions (the miner never writes this table; the weights carry
the value CS last set) already covers the write path that matters.

## Traps

1. ⛔⛔ **`0 * NULL = NULL`, and it would nuke `p_score` fleet-wide.** The dial is 0, so a NULL
   `s_intents` is not "no contribution" — it is a NULL that propagates through the whole weighted sum
   and takes `p_score`, `urgency` and both tier gates with it, on **every machine**. The inert dial
   is exactly what would hide it in review. Hence: a CHECK that makes a zero norm impossible, AND
   arithmetic that survives one anyway (`NULLIF` → `COALESCE(..., 1)` → `s_intents = 0`). Belt and
   braces on the one expression where a NULL is unsurvivable.
2. ⛔ **`CREATE OR REPLACE VIEW` may only ADD columns at the END.** `s_intents` reads best next to
   `s_holes` and must go after `holes_d`. Putting it where it belongs costs a DROP + CREATE, which
   would cascade to `v_machine_service_priority`. Do not.
3. ⛔⛔ **The parking lot's "SIX times" is wrong — it is FIVE.** `pg_get_viewdef` returns five
   occurrences of the weighted sum. The sixth in that enumeration ("the high_urgency reason branch"
   and "the reason cascade") is one site counted twice. ⭐ **Do not carry the claim into the guard:**
   assert that the count of `w_intents * ms.s_intents` **equals** the count of
   `w_runout * ms.s_runout`. That guard stays true when a sixth site is added later; a hard-coded 5
   would silently pass a view that gained a site without the new term.
4. ⛔⛔ **Shipping the dial at 0 makes the miner structurally unable to ever move it.** The proposal
   step is multiplicative — `v_prop := v_cur * (1 ± v_delta/100)` — so `v_cur = 0` computes `0`, which
   trips `round_to_equal` and is refused. **Forever, and by name of the wrong thing.** So this unit
   must NOT set the map row active: a reader would see `round_to_equal` and conclude the evidence was
   too thin, when the truth is the dial has no starting value. The map row records the dial, the
   s_term and the measured monotonicity with `is_active = false` and a note that says exactly this.
   **The CS ask is a number, not a re-decision.**
5. ⚠️ **The feature has TWO levels on the live fleet** — 28 machines at 0, 3 at 1, max 1. `corr` is
   defined and lands at exactly −1.000, which looks like the strongest mapping in the table and is
   resting on three machines. Record the distinct-level count next to the correlation so the
   thinness is on the face of the evidence, not behind it.
6. ⚠️ **A non-zero dial can only RAISE scores**, so it can only push machines UP through
   `p1_threshold` / `p2_threshold` — and the machines it lifts most are the ones with **no** open
   intents. At `w_intents = 0.30` a quiet machine gains a flat +30 on a scale whose P1 gate is 50.
   That is a large move for a first value and is the substance of the CS ask.
7. ⏸️ **Pre-existing, named not fixed:** `p_score` is cast `numeric(6,2)`. The dials are unbounded
   above, so a dial set past ~97 overflows the cast and errors the whole view for every caller. True
   of all eight dials, not introduced here.

## Alternative considered and rejected

**Negative weight on a plain `s_intents` (higher = more intents).** Fewer moving parts — no
inversion to explain — and it matches the raw feature direction, so `monotonicity` would read
`+1.000` instead of `−1.000`. Rejected: it makes `w_intents` the only signed dial in the set, breaks
the `param_rewards` idiom the map and the miner already share (`fill_pct → w_capacity` at `'low'`),
and pushes the direction into a value CS can typo. The sign belongs in the term, where a fixture can
pin it; not in a number CS types into a settings row.

## Cody handoff checklist

- **Article 2/3** — no RLS change, no new table; assert the existing `pick_urgency_params` grants and
  RLS state are byte-unchanged across the migration.
- **Article 7** — `v_machine_priority` is replaced, not dropped; `v_machine_service_priority` must
  survive with an unchanged definition.
- **Article 12** — no plan-table write; assert `refill_plan_output` untouched.
- **Article 15/16** — `v_machine_priority` is the canonical machine-priority object
  (PRD-063/074, METRICS_REGISTRY). The registries must record the eighth dial and the s_term, and the
  map row is the pin that couples the dial to the feature that justifies it.
- **PRD-110 LAW 4** — the whole point: prove the live `p_score` set is IDENTICAL across the
  migration, by identity (machine_id, p_score, urgency, p_tier), not by count.
