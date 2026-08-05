# DARA PROPOSAL — PRD-110 P4.1 + P4.2: feedback ledger, proposal queue, planning pins

Requested by the PRD-110 loop (leg 79). Companion to BUILD-SPEC P4.1 / P4.2.
Status: DESIGN ONLY. Not applied. Goes to Cody before any migration is written.

---

## Design problem

BUILD-SPEC P4.1/P4.2 asks for a learning loop with three distinct responsibilities that a single
table would smear together: **raw feedback** (many channels, high volume, never edited), **gated
proposals** (a review queue with a lifecycle), and **standing constraints** (the small, precious set
of rules the engines actually read at plan time). These are three different lifetimes and three
different consumers, so they are three tables.

The business invariant that matters most is **provenance**: fixture 16 requires that a driver's
2-tap "don't reduce Oreo" survive as an unbroken chain into a `protect_depth` pin that the next plan
respects. If any link stores a summary instead of a reference, the chain is decorative.

⛔ **A live constraint discovered before designing:** `driver_propose_adjustment` already exists and
already writes **three** channels (`driver_recommendations`, `driver_feedback`,
`refill_edit_signals`). BUILD-SPEC says the 2-tap **wraps** it. So `feedback_ledger_v3` must **not**
become a fourth parallel channel that re-states the same event. It references
`driver_recommendations.rec_id` and treats the existing verb as the writer of record for the driver
path. Versioned addition, no destructive change (LAW 3).

Queries to support: (1) open feedback for a machine, newest first; (2) the pending proposal queue for
the CS review board; (3) ⭐ **the hot one — "give me every active pin for this machine/shelf/product"
on every engine run**, which must be an index hit, not a scan with date arithmetic.

## Proposed schema

```sql
-- ============ P4.1a  feedback_ledger_v3 : canonical multi-channel raw feedback ============
CREATE TABLE IF NOT EXISTS public.feedback_ledger_v3 (
  feedback_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  -- WHERE the signal came from. 'driver' rows are wrappers over driver_recommendations.
  channel            text NOT NULL CHECK (channel IN ('driver','client','cs','miner')),
  -- provenance into the PRE-EXISTING driver path. NOT a duplicate of that row: a pointer to it.
  driver_rec_id      uuid REFERENCES public.driver_recommendations(rec_id) ON DELETE SET NULL,
  -- target. machine is always known; shelf/product may be absent for a machine-wide remark.
  machine_id         uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id           uuid     REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id   uuid     REFERENCES public.boonz_products(product_id)     ON DELETE RESTRICT,
  -- WHAT is being asked. Maps 1:1 onto the pin kinds a proposal may later mint.
  intent             text NOT NULL CHECK (intent IN
                       ('dont_reduce','always_stock','never_stock','more_facings',
                        'less_facings','wrong_product','machine_issue','other')),
  note               text NOT NULL CHECK (length(trim(note)) >= 10),
  submitted_by       uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  -- lifecycle: raw feedback is triaged exactly once, then frozen.
  status             text NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open','proposed','dismissed')),
  triaged_at         timestamptz,
  triage_note        text,
  CONSTRAINT chk_fbl_v3_driver_channel
    CHECK ((channel = 'driver') = (driver_rec_id IS NOT NULL)),
  CONSTRAINT chk_fbl_v3_triage
    CHECK ((status = 'open') = (triaged_at IS NULL))
);
COMMENT ON TABLE public.feedback_ledger_v3 IS
  'PRD-110 P4.1. Append-only raw feedback, all channels. Driver rows WRAP driver_recommendations (see driver_rec_id) rather than restating them. RPC-only writers.';

-- ============ P4.1b  feedback_proposals_v3 : the gated review queue ============
-- Column order and status vocabulary deliberately mirror rotation_proposals_v3 /
-- facing_proposals_v3 / reallocation_proposals_v3 so the CS board renders all four identically.
CREATE TABLE IF NOT EXISTS public.feedback_proposals_v3 (
  proposal_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date          date NOT NULL,
  proposed_at        timestamptz NOT NULL DEFAULT now(),
  machine_id         uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id           uuid     REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id   uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  -- the pin this proposal would mint if approved.
  pin_kind           text NOT NULL CHECK (pin_kind IN
                       ('min_facing','protect_depth','always_stock','never_stock')),
  pin_value          integer CHECK (pin_value IS NULL OR pin_value >= 0),
  pin_mode           text NOT NULL CHECK (pin_mode IN ('perpetual','until')),
  pin_expires_at     timestamptz,
  -- provenance. NOT NULL + non-empty: a proposal with no evidence is not a proposal.
  feedback_ids       uuid[] NOT NULL CHECK (array_length(feedback_ids,1) >= 1),
  trigger_reason     text NOT NULL,
  scoring_breakdown  jsonb NOT NULL DEFAULT '{}'::jsonb,
  status             text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','approved','rejected','superseded')),
  reviewed_by        uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  reviewed_at        timestamptz,
  review_note        text,
  applied_pin_id     uuid,   -- FK added after planning_pins_v3 exists (see below)
  CONSTRAINT chk_fpr_v3_mode  CHECK ((pin_mode = 'until') = (pin_expires_at IS NOT NULL)),
  CONSTRAINT chk_fpr_v3_value CHECK (
    (pin_kind IN ('min_facing','protect_depth') AND pin_value IS NOT NULL AND pin_value >= 1)
 OR (pin_kind IN ('always_stock','never_stock')  AND pin_value IS NULL)),
  CONSTRAINT chk_fpr_v3_review CHECK ((status = 'pending') = (reviewed_at IS NULL))
);

-- ============ P4.2  planning_pins_v3 : the standing constraints the engines read ============
CREATE TABLE IF NOT EXISTS public.planning_pins_v3 (
  pin_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  machine_id         uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id           uuid     REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id   uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  kind               text NOT NULL CHECK (kind IN
                       ('min_facing','protect_depth','always_stock','never_stock')),
  value              integer CHECK (value IS NULL OR value >= 0),
  mode               text NOT NULL CHECK (mode IN ('perpetual','until')),
  expires_at         timestamptz,
  -- provenance chain. 'cs_direct' is the ONLY source allowed to carry no feedback.
  source             text NOT NULL DEFAULT 'feedback'
                       CHECK (source IN ('feedback','cs_direct')),
  feedback_ids       uuid[] NOT NULL DEFAULT '{}'::uuid[],
  proposal_id        uuid REFERENCES public.feedback_proposals_v3(proposal_id) ON DELETE RESTRICT,
  created_by         uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  -- revocation is a SUPERSEDE, never an UPDATE-in-place and never a DELETE:
  -- fixture 16 asserts the chain, fixture 21's sibling rule is "history preserved, no overwrite".
  revoked_at         timestamptz,
  revoked_by         uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  revoke_reason      text,
  CONSTRAINT chk_pin_v3_mode  CHECK ((mode = 'until') = (expires_at IS NOT NULL)),
  CONSTRAINT chk_pin_v3_value CHECK (
    (kind IN ('min_facing','protect_depth') AND value IS NOT NULL AND value >= 1)
 OR (kind IN ('always_stock','never_stock')  AND value IS NULL)),
  CONSTRAINT chk_pin_v3_provenance CHECK (
    source = 'cs_direct' OR array_length(feedback_ids,1) >= 1),
  CONSTRAINT chk_pin_v3_revoke CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);

ALTER TABLE public.feedback_proposals_v3
  ADD CONSTRAINT fpr_v3_applied_pin_fk
  FOREIGN KEY (applied_pin_id) REFERENCES public.planning_pins_v3(pin_id) ON DELETE SET NULL;

-- ============ the canonical read object (Article 16) ============
-- Engines and L0 read THIS, never the base table. "Active" is one definition, in one place.
CREATE OR REPLACE VIEW public.v_planning_pins_active_v3 AS
SELECT p.*,
       (p.expires_at IS NOT NULL) AS is_time_boxed,
       CASE WHEN p.expires_at IS NULL THEN NULL
            ELSE GREATEST(0, EXTRACT(day FROM p.expires_at - now())::int) END AS days_remaining
FROM public.planning_pins_v3 p
WHERE p.revoked_at IS NULL
  AND (p.expires_at IS NULL OR p.expires_at > now());
COMMENT ON VIEW public.v_planning_pins_active_v3 IS
  'PRD-110 P4.2 CANONICAL. The only definition of an active pin: not revoked AND not expired. Engines/L0 read this, never planning_pins_v3 directly.';
```

## Indexes

```sql
-- (1) "open feedback for this machine, newest first" — the triage screen.
CREATE INDEX IF NOT EXISTS ix_fbl_v3_machine_open
  ON public.feedback_ledger_v3 (machine_id, created_at DESC) WHERE status = 'open';

-- (2) the pending review queue, the CS board's only query.
CREATE INDEX IF NOT EXISTS ix_fpr_v3_pending
  ON public.feedback_proposals_v3 (plan_date, proposed_at DESC) WHERE status = 'pending';

-- (3) THE HOT PATH: every engine run resolves pins per machine. Partial on live rows only,
--     so the index stays roughly the size of the active pin set, not the history.
CREATE INDEX IF NOT EXISTS ix_pin_v3_lookup
  ON public.planning_pins_v3 (machine_id, boonz_product_id, kind) WHERE revoked_at IS NULL;

-- (4) INVARIANT AS DDL, not as a trigger: at most ONE live pin per (target, kind).
--     coalesce() because NULL shelf_id (a machine-wide pin) would otherwise never collide.
CREATE UNIQUE INDEX IF NOT EXISTS ux_pin_v3_active_one_per_kind
  ON public.planning_pins_v3
     (machine_id, coalesce(shelf_id,'00000000-0000-0000-0000-000000000000'::uuid),
      boonz_product_id, kind)
  WHERE revoked_at IS NULL;

-- (5) ⭐ THE CONTRADICTION GUARD, also pure DDL. always_stock and never_stock on the same target
--     are mutually exclusive, so both kinds share ONE uniqueness bucket: inserting either while
--     the other is live raises 23505. No trigger, no race, no way to write an incoherent rule.
CREATE UNIQUE INDEX IF NOT EXISTS ux_pin_v3_stock_policy_exclusive
  ON public.planning_pins_v3
     (machine_id, coalesce(shelf_id,'00000000-0000-0000-0000-000000000000'::uuid),
      boonz_product_id)
  WHERE revoked_at IS NULL AND kind IN ('always_stock','never_stock');
```

## RLS policies

⭐ Shape taken from the **live** v3 fleet convention (S-104), read off `rotation_proposals_v3` and
`facing_proposals_v3` rather than invented: RLS on, exactly one permissive SELECT policy to
`authenticated`, and — per **S-88, RLS is not a write guard, THE GRANT is** — `authenticated`
receives **SELECT only**. Every write goes through a SECURITY DEFINER `_v3` RPC.

⛔ Note `plan_edits_v3` does NOT follow this (it grants `authenticated` full DML). That is the older,
looser shape. These are proposal/constraint tables, so they take the tight one.

```sql
ALTER TABLE public.feedback_ledger_v3    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feedback_proposals_v3 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.planning_pins_v3      ENABLE ROW LEVEL SECURITY;

CREATE POLICY fbl_v3_select ON public.feedback_ledger_v3    FOR SELECT TO authenticated USING (true);
CREATE POLICY fpr_v3_select ON public.feedback_proposals_v3 FOR SELECT TO authenticated USING (true);
CREATE POLICY pin_v3_select ON public.planning_pins_v3      FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.feedback_ledger_v3, public.feedback_proposals_v3,
              public.planning_pins_v3 FROM authenticated;
GRANT SELECT ON public.feedback_ledger_v3, public.feedback_proposals_v3,
                public.planning_pins_v3, public.v_planning_pins_active_v3 TO authenticated;
```

⚠️ **S-121 applies:** the golden harness runs as `postgres` and bypasses RLS, so a fixture can never
prove this ACL. Verify the grant with `SET ROLE authenticated`, never with a fixture run.

## Tradeoffs and alternatives

**Rejected — one `feedback_v3` table with a `stage` column** (raw → proposed → pinned). Tempting, and
it would make the provenance chain trivially a single row. Rejected because the three stages have
incompatible constraint sets: a pin must satisfy the kind/value pairing and the active-uniqueness
index, and raw feedback satisfies neither. Every CHECK would have to be conditioned on `stage`, and
the partial unique indexes that make the contradiction guard possible would have to be conditioned
too. That is a state machine pretending to be a table.

**Rejected — pins as `UPDATE`-in-place with a `status` column.** Cheaper reads, but it destroys the
provenance fixture 16 exists to assert, and it makes "what constrained the plan on 2026-08-04?"
unanswerable. Supersede-style costs one partial index and answers it forever.

**Rejected — a trigger for the always/never contradiction.** A trigger is racy under concurrency
(two sessions each see no conflicting row, both commit) and it is code that can be dropped. Index (5)
makes the contradiction physically unrepresentable. ⭐ **Prefer DDL that cannot be bypassed over
plpgsql that must be trusted.**

**Accepted cost — `feedback_ids uuid[]` is denormalized** rather than a junction table. A proposal
cites a handful of feedback rows and is never queried _by_ feedback_id, so a junction table would add
a join to every read to serve a query nobody makes. If a "show me every proposal citing this
feedback" screen ever appears, add a GIN index on the array; do not normalize.

**Open question for Cody, deliberately not decided here:** should `planning_pins_v3` be added to
Appendix A as a protected entity? It is a small table that directly steers plan output, which argues
yes. Dara's lean is **yes**, but that is a constitutional call, not a schema call.

## Cody handoff checklist

- **Article 2 / 3** — RLS shape and the SELECT-only grant; writes are RPC-only (none written yet).
- **Article 4 / 8** — provenance and audit attribution on pins (`created_by`, `revoked_by`).
- **Article 5** — `status` on both queues is a state machine; the transition verb is not yet written.
- **Article 6** — untouched: nothing here reads or writes `warehouse_inventory.status`.
- **Article 12** — forward-only, additive, `IF NOT EXISTS` throughout; no existing object altered
  except the one `ADD CONSTRAINT` that closes the proposals→pins FK cycle.
- **Article 14** — three new tables + one view ⇒ an ADR is required before apply.
- **Article 16** — `v_planning_pins_active_v3` is declared the canonical "active pin" object;
  METRICS/RPC registries to be updated in the same unit.
- **Appendix A** — the open question above.
