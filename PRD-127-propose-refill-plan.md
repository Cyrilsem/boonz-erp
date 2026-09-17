# PRD-127 — Propose refill plan

**Owner:** CS
**Written:** reconstructed 2026-09-17 by the ONE LOOP session that implemented it (see
"A note on this document" at the bottom)
**Status:** ready to build

---

## 1. Problem

`engine_add_pod` + `confirm_and_build` produce a plan, but the only way to see it before it
hits `refill_dispatching` is to read raw `pod_refill_plan`/`pod_swaps` rows or open the `/refill`
FE. There is no way to ask, in a sentence, "what would tomorrow's plan look like", get back
something a person can read in ten seconds, push back on one line ("actually put 6 on
AMZ-1046 A02, not 4"), and only then run the real build. Every adjustment today means either
editing the FE after the fact or re-running the whole engine.

Two smaller, related gaps: there is no durable way to tell the engine "never recommend this
product again, it's out of stock in the UAE" without hand-editing a table each time, and the
17 September incident (three known bugs below) showed that CS-facing tools and engine-facing
tools sharing unreviewed logic drift apart silently.

## 2. Goal

A read-only, chat-native "what would happen" function CS (or a future conversational layer)
can call before committing to a plan: `propose_refill_plan`. It reads live data, proposes a
plan, and returns something already formatted for a chat reply — never a dump of raw rows. It
must never write anything, so it is safe to call as many times as needed while iterating. A
durable directives table lets CS steer the engine ("block this product") without a one-off SQL
edit each time.

## 3. `refill_directives`

```sql
CREATE TABLE public.refill_directives (
  directive_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  directive_type text NOT NULL CHECK (directive_type = 'block'),
  target_kind    text NOT NULL CHECK (target_kind IN ('machine','pod_product','boonz_product')),
  target_id      uuid NOT NULL,
  target_name    text NOT NULL,
  note           text NOT NULL CHECK (length(btrim(note)) >= 10),
  active         boolean NOT NULL DEFAULT true,
  created_by     uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at     timestamptz NOT NULL DEFAULT now(),
  retired_by     uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  retired_at     timestamptz,
  retired_reason text
);
```

Only `directive_type = 'block'` is implemented in this PRD (widen the CHECK the day a second
type is actually needed — do not pre-build unused types). A `block` on a `pod_product` or
`boonz_product` means: never recommend adding more of it, anywhere, in `propose_refill_plan`'s
output (Removes of it are unaffected — the point is "stop buying it," not "stop clearing old
stock"). A `block` on a `machine` means: skip that machine entirely for this run.

`add_refill_directive(p_directive_type text, p_target text, p_note text, p_caller uuid DEFAULT
auth.uid()) RETURNS uuid` and `retire_refill_directive(p_directive_id uuid, p_reason text,
p_caller uuid DEFAULT auth.uid()) RETURNS void`, both SECURITY DEFINER, both reject a caller
whose role is not `operator_admin`/`superadmin`/`manager` (NULL `auth.uid()` — a trusted
service/cron context — passes through). `p_target` is resolved by exact case-insensitive,
trimmed name match against `machines.official_name`, `pod_products.pod_product_name`, and
`boonz_products.boonz_product_name` combined; zero matches or more than one match RAISES with
the candidates found, rather than guessing which table the caller meant.

Seed: one `block` row on the boonz product **Oreo Cookie - Regular**, note "out of stock in the
UAE", `created_by = 82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d`.

## 4. `propose_refill_plan(p_plan_date date, p_machine_names text[], p_overrides jsonb)`

`STABLE`, `SECURITY DEFINER`, `SET search_path TO 'public'`, `SET statement_timeout = '120s'`.
Same role gate as the directive writers (NULL passes; else
operator_admin/superadmin/manager/warehouse).

**Scope.** `p_machine_names IS NOT NULL` → exactly those machines (raise on an unknown name).
`p_machine_names IS NULL` → the plan date's confirmed pick list
(`machines_to_visit.status IN ('picked','cs_added')` for `p_plan_date`), the same set
`engine_add_pod` would build from — "the full confirmed set" in Block D's timing instruction
means this default path.

**Lane list.** Every WEIMI lane (`weimi_shelf_now`, D2) of every in-scope machine, joined to
`shelf_configurations` for `shelf_id` (excluding phantom shelves) and to `product_mapping` for
the best-matching Active `boonz_product_id` (same preference order `engine_add_pod` uses:
machine-specific mapping over global default). Velocity (`lane_dvel`, already a per-day figure)
and price (`effective_price_aed`) join from the existing canonical views `v_lane_grain` and
`v_current_price_filled` by `(machine_id, pod_product_id)` — reused, not recomputed. No lane is
excluded from consideration by velocity or by any ranking; every lane gets a `reason_code`
(section 6), and a lane whose `reason_code` computation falls through unclassified is a hard
`RAISE`, not a silent default.

**D1 target.** `target_stock = max_stock` when `lane_dvel >= hero_velocity_floor` (from
`refill_policy_params`) or the resolved `source_of_supply = 'venue_team'`, else
`LEAST(10, max_stock)`. `need_raw = GREATEST(target_stock - current_stock, 0)`, forced to 0 for
a dead lane (`lane_dvel = 0`).

**D3 stock.** One pool per `boonz_product_id`, computed by calling `wh_available_for` once per
distinct routing class present among that product's in-scope lanes (at most two calls: one
`venue_team`-routed machine, one not) and summing the returned `free_stock` rows — `
wh_available_for` itself already applies the D3 routing rule, the phantom-batch exclusion
(`_is_phantom_wh_row_v3`), quarantine, and pin subtraction, so this reuses it exactly rather
than re-deriving the same predicate a second time and risking drift (the 17 September lesson).

**Global allocation.** Lanes needing the same `boonz_product_id` are ordered by `aed_at_risk`
descending (section 5) and each is granted `LEAST(need_raw, GREATEST(pool - prior_need, 0))`
against a running sum of `need_raw` for every higher-`aed_at_risk` lane already served —
identical in shape to `engine_add_pod`'s own `prior_need`/`final_qty` window, with the ORDER BY
changed from velocity to `aed_at_risk` per this PRD's own priority (money at risk, not units).
An `expired_on_shelf` lane's need is boosted by
`refill_swap_params.expired_priority_boost_aed` before ordering, so a real expiry problem is
served before an ordinary top-up of equal or slightly higher raw AED risk — the boost lives in
`refill_swap_params`, not inlined, so CS can retune it without a migration.

**D4 substitution.** A lane with `current_stock > 0` and an Active `pod_inventory` row expired
before today calls `find_substitutes_for_shelf` (existing, PRD-125 D4) for a candidate. A
candidate under `refill_swap_params.min_substitute_stock_units` is treated as not found (not
worth a special trip for).

**Directives.** A lane whose resolved `pod_product_id`/`boonz_product_id` matches an active
`block` directive, or whose machine does, is excluded from any fill recommendation and reported
in `directives_applied`.

**Overrides.** `p_overrides` is `[{"machine_name": "...", "shelf_code": "...", "qty": n}, ...]`
— an explicit CS instruction for one lane this call only (not durable; for durable rules use
`refill_directives`). An override that does not resolve to an in-scope lane is reported in
`overrides_unresolved`, not a hard error — it is normal for a chat instruction to arrive before
the lane it names is confirmed onto today's pick list.

**Writes nothing.** No `INSERT`/`UPDATE`/`DELETE` statement appears anywhere in the function
body. Proven in the acceptance suite (A1) with real per-table `AFTER INSERT OR UPDATE OR DELETE`
triggers on the five protected tables, installed and dropped inside one rolled-back transaction
— Postgres event triggers only fire on DDL, so a genuine DML guard is the correct
implementation of "prove it never writes," not the literal event-trigger mechanism a first
draft of this PRD assumed.

## 5. The rendered chat summary

`fill` entries are plain strings, one per actionable lane, produced inside the function —
never a raw row a caller has to format itself. Example shape for one machine:

```
AMZ-1046-2406-O1 (car 1) — 3 refills, 1 substitute, 1 exception
  A02: Refill Oreo Cookie - Chocolate, 4 -> 8 (+4)
  A05: Refill Red Bull Original, 2 -> 6 (+4, warehouse short: only 4 of 8 available)
  A09: Remove Evian - 1L (expired on shelf) -> Al Ain Zero, add 6
Exceptions:
  A16: Evian - 1L expired on shelf, no substitute found — needs a human call
```

The full returned `jsonb` is `{plan_date, machines: [{machine_name, car_no, header, fill: [...],
exceptions: [...]}], directives_applied: [...], overrides_applied: [...],
overrides_unresolved: [...], totals: {machines, lanes_total, fills, removes, exceptions,
blocked_by_directive, by_reason_code: {...}}, duration_ms}`. `by_reason_code` is a small
histogram (at most ten keys), not a per-lane dump — it is what lets the acceptance suite prove
every lane got a reason code without paying the token cost of listing every lane (that cost is
exactly what pre-rendering strings was supposed to avoid, per A9).

## 6. Reason codes (exhaustive, first match wins)

| Order | Code                          | Meaning                                                            |
| ----- | ----------------------------- | ------------------------------------------------------------------ |
| 1     | `no_active_mapping`           | WEIMI shows a product with no Active `product_mapping` — exception |
| 2     | `override_applied`            | `p_overrides` set this lane's qty explicitly                       |
| 3     | `blocked_directive`           | An active `block` directive suppresses this lane                   |
| 4     | `expired_on_shelf_substitute` | Expired Active lot on shelf, substitute found and proposed         |
| 5     | `expired_on_shelf_no_rule`    | Expired Active lot on shelf, no substitute — exception             |
| 6     | `dead_no_velocity`            | `lane_dvel = 0`, no fill recommended                               |
| 7     | `ok_at_target`                | `current_stock >= target_stock`, nothing to do                     |
| 8     | `refill_recommended`          | `need_raw > 0`, fully allocatable                                  |
| 9     | `refill_partial_wh_short`     | `need_raw > 0`, partially allocatable                              |
| 10    | `refill_blocked_no_wh`        | `need_raw > 0`, zero allocatable — exception                       |

A lane that matches none of the above is a bug, not a default: the function raises rather than
returning a lane with a null reason code.

## 7. Acceptance criteria

All rollback-safe (a synthetic test never leaves a trace); A1, A2, A3, A8 run against real
2026-09-17 data; A6 uses one synthetic short-dated lot inserted and rolled back in the same
transaction as the check.

| #   | Criterion                                                                                                                                                                                                                                                                                                                                          |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | `propose_refill_plan` writes zero rows to `pod_refill_plan`, `refill_plan_output`, `refill_dispatching`, `pod_inventory`, `warehouse_inventory` — proven with real per-table DML guard triggers, not asserted                                                                                                                                      |
| A2  | Every lane examined gets exactly one reason code; `totals.by_reason_code` values sum to `totals.lanes_total`; no lane is unclassified                                                                                                                                                                                                              |
| A3  | With the seeded Oreo Cookie - Regular `block` directive active, no `fill` string across the whole output recommends adding it, and it never appears in `directives_applied` mistakenly cleared                                                                                                                                                     |
| A4  | The warehouse pool for a boonz product with a known phantom/reserved-for-another-machine batch matches an independent query using the exact same predicates as `wh_available_for` — no drift                                                                                                                                                       |
| A5  | Synthetic: three lanes need 4, 3, and 2 units respectively of one boonz product; only 6 units of free stock exist. The two highest-`aed_at_risk` lanes are filled in full (4 + 2, or 4 + 3 depending on which pair sums to <= 6 first) and the remainder gets `refill_partial_wh_short` or `refill_blocked_no_wh`, strictly in `aed_at_risk` order |
| A6  | A synthetic Active lot with `expiration_date < CURRENT_DATE` on a real shelf with real stock produces `expired_on_shelf_substitute` (when a substitution rule matches) or `expired_on_shelf_no_rule` (when none does), matching what `find_substitutes_for_shelf` alone would return for the same shelf                                            |
| A7  | Changing `refill_swap_params.expired_priority_boost_aed` in a rolled-back transaction changes which lane wins a contended allocation between an expired-on-shelf need and an ordinary refill need of similar `aed_at_risk` — proving the weight is read from the table, not hardcoded                                                              |
| A8  | Every element of every machine's `fill` and `exceptions` array is a JSON string; the top-level return contains no raw per-lane row array                                                                                                                                                                                                           |
| A9  | The serialised `jsonb` output for eight machines is <= 6,000 tokens at 4 characters per token                                                                                                                                                                                                                                                      |
| A10 | `add_refill_directive` with a target name matching zero or more than one of `machines`/`pod_products`/`boonz_products` raises, naming what it found, instead of guessing                                                                                                                                                                           |
| A11 | `add_refill_directive`, `retire_refill_directive`, and `propose_refill_plan` all reject a caller whose `user_profiles.role` is below `operator_admin`/`manager`/`superadmin` (`propose_refill_plan` also accepts `warehouse`)                                                                                                                      |

## A note on this document

This file did not exist anywhere in the repository or its git history when the ONE LOOP session
implementing PRD-127 started (verified: `git log --all` for the filename across every branch,
and a filesystem search of the whole working tree, both came back empty). Rather than block on
a document CS's own goal-prompt referenced as already written, the session reconstructed it from
the goal prompt's own inline specification — which was detailed enough to fully determine
sections 3, 4, and the non-negotiables of section 6 — and made the doctrine-consistent call on
the parts the prompt didn't spell out verbatim (the exact chat-summary shape in section 5, the
precise reason-code taxonomy in section 6, and the eleven acceptance criteria in section 7).
Every such call is logged in `DECISIONS-2026-09-17.md`. If this reconstruction gets anything
wrong relative to what CS actually meant, the fix is a follow-up PRD-127 revision, not a silent
rewrite of this file after the fact.
