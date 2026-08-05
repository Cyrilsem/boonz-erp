-- PRD-110 P4.3d — the miner-run log (schema)
-- Dara design + Cody review (leg 89).
-- WHY: the weekly miner cron ships in DRY-RUN (LAW 4, and the fixture/live
-- contention recorded in the PARKING-LOT). A dry run whose findings are not
-- persisted is theatre: cron.job_run_details keeps a return MESSAGE, not the
-- miner's jsonb payload. This table is where a dry run's answer survives.
-- Articles: 2 (RLS on), 4 (no SECURITY DEFINER here), 7 (append-only incl.
--           TRUNCATE), 12 (forward-only, additive), 14 (a run log is an event
--           stream, not a materialised snapshot of a query).

--------------------------------------------------------------- (1) dials -----
-- Both default TRUE. Flipping either to FALSE is the parked DECISIONS-READY
-- activation: one UPDATE, no migration, no cron edit.
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS miner_weekly_pick_dry_run boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS miner_weekly_edit_dry_run boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS miner_fixture_epoch       date    NOT NULL DEFAULT DATE '2030-01-01';

COMMENT ON COLUMN public.refill_policy_params.miner_weekly_pick_dry_run IS
  'PRD-110 P4.3d. TRUE = the weekly cron runs mine_pick_history_v3 with p_dry_run, minting nothing. Flip to FALSE to let the pick miner mint live proposals (parked CS decision). ⛔ Flipping this makes golden fixture 58 RED whenever a live pending w_* proposal exists: ux_pwp_one_pending_per_param is a GLOBAL one-pending-row-per-dial index and fixture 58 hard-RAISEs on any foreign pending row.';
COMMENT ON COLUMN public.refill_policy_params.miner_weekly_edit_dry_run IS
  'PRD-110 P4.3d. TRUE = the weekly cron runs mine_edit_history_v3 with p_dry_run. Flip to FALSE to let the edit miner mint live pin proposals (parked CS decision). ⛔ Flipping this can redden golden fixture 57, whose anchor machine mA is chosen as one with no non-miner ledger rows and no pins, and whose expected cluster is refused by the miner if a live proposal is already pending on the same target.';
COMMENT ON COLUMN public.refill_policy_params.miner_fixture_epoch IS
  'Dates >= this belong to the golden harness synthetic universe (LAW 12 2030 convention). Used to tell a synthetic pending proposal from a real one when explaining why a miner refused. HORIZON WARNING: revisit well before 2030-01-01.';

------------------------------------------------------------ (2) the table ----
CREATE TABLE IF NOT EXISTS public.miner_runs_v3 (
  run_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- One weekly invocation writes one row per miner sharing a batch_id, so a
  -- board can show "last week's mining" as a unit even when one leg errored.
  batch_id               uuid        NOT NULL,
  miner                  text        NOT NULL
                           CHECK (miner IN ('mine_edit_history_v3','mine_pick_history_v3')),
  invoked_by             text        NOT NULL
                           CHECK (invoked_by IN ('cron','manual','fixture')),
  dry_run                boolean     NOT NULL,
  status                 text        NOT NULL CHECK (status IN ('ok','error')),
  -- Normalised across two miners that disagree on their own vocabulary:
  -- the pick miner returns {ok, proposals_created, proposals_would_create},
  -- the edit miner returns {status, proposals_made}. Neither name is used here.
  proposals_created      integer     NOT NULL DEFAULT 0 CHECK (proposals_created >= 0),
  proposals_would_create integer     NOT NULL DEFAULT 0 CHECK (proposals_would_create >= 0),
  -- [{code, n}] — WHY a candidate did not become a proposal. Without this a
  -- silently-refused miner and a miner with nothing to say look identical.
  refusals               jsonb       NOT NULL DEFAULT '[]'::jsonb
                           CHECK (jsonb_typeof(refusals) = 'array'),
  -- Conditions the RUN detected about its own environment, not about the data.
  warnings               text[]      NOT NULL DEFAULT '{}'::text[],
  -- The miner's full return value, verbatim. This is the point of the table.
  payload                jsonb       NOT NULL DEFAULT '{}'::jsonb,
  error_text             text,
  error_state            text,
  started_at             timestamptz NOT NULL,
  finished_at            timestamptz NOT NULL DEFAULT now(),
  duration_ms            integer     NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
  created_at             timestamptz NOT NULL DEFAULT now(),
  -- ⛔ Both CHECKs are total: every operand is NOT NULL or an IS NOT NULL test,
  --    so neither can evaluate to NULL. S-126 — a CHECK that evaluates to NULL
  --    PASSES, so a partial invariant here would be decoration.
  CONSTRAINT miner_runs_v3_error_coherent
    CHECK ((status = 'error') = (error_text IS NOT NULL)),
  CONSTRAINT miner_runs_v3_dry_run_mints_nothing
    CHECK (NOT dry_run OR proposals_created = 0),
  CONSTRAINT miner_runs_v3_finished_after_started
    CHECK (finished_at >= started_at)
);

COMMENT ON TABLE public.miner_runs_v3 IS
  'PRD-110 P4.3d. Append-only log of every WS-H2 / WS-H4 miner invocation. Exists because the weekly cron ships in dry-run and cron.job_run_details keeps a return message, not the payload: without this table a dry-run miner''s findings vanish and the schedule is theatre. Written by run_weekly_miners_v3.';
COMMENT ON COLUMN public.miner_runs_v3.proposals_would_create IS
  'What the miner WOULD have minted had it not been in dry-run. In a live run this equals the number it attempted; proposals_created is what survived the dedup gate.';
COMMENT ON COLUMN public.miner_runs_v3.refusals IS
  'jsonb array of {code, n}. Refusal codes come from the miners verbatim (e.g. pending_exists, below_concordance_band, trim_no_ceiling_kind). A run with zero candidates and a run whose every candidate was refused are different events.';
COMMENT ON COLUMN public.miner_runs_v3.warnings IS
  'Conditions the wrapper detected about the RUN''s environment. synthetic_pending_blocks_live_minting = a pending picker_weight_proposals_v3 row dated at/after miner_fixture_epoch is occupying the GLOBAL one-pending-row-per-dial slot, so the live miner is being refused by golden-harness residue rather than by evidence.';

--------------------------------------------------------- (3) append-only -----
CREATE OR REPLACE FUNCTION public.tg_miner_runs_v3_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  -- ⛔ Cody, Article 7: a row-level trigger never sees a TRUNCATE, and
  --    GRANT ALL TO service_role carries TRUNCATE — hence the statement-level
  --    sibling below. This branch covers the case where the two are merged.
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'miner_runs_v3 is append-only: TRUNCATE refused';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'miner_runs_v3 is append-only: DELETE refused (run_id %)', OLD.run_id;
  END IF;
  -- ⛔ Unlike pipeline_runs_v3 there is NO approval dimension and no column a
  --    human may revise: a mining run is a completed observation. Refuse the
  --    whole UPDATE rather than enumerate columns, so a column added by a
  --    future migration cannot become quietly mutable.
  RAISE EXCEPTION 'miner_runs_v3 is append-only: UPDATE refused (run_id %)', OLD.run_id;
END
$fn$;

CREATE OR REPLACE FUNCTION public.tg_miner_runs_v3_no_truncate()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  RAISE EXCEPTION 'miner_runs_v3 is append-only: TRUNCATE refused';
END
$fn$;

DROP TRIGGER IF EXISTS tg_miner_runs_v3_append_only ON public.miner_runs_v3;
CREATE TRIGGER tg_miner_runs_v3_append_only
  BEFORE UPDATE OR DELETE ON public.miner_runs_v3
  FOR EACH ROW EXECUTE FUNCTION public.tg_miner_runs_v3_append_only();

DROP TRIGGER IF EXISTS tg_miner_runs_v3_no_truncate ON public.miner_runs_v3;
CREATE TRIGGER tg_miner_runs_v3_no_truncate
  BEFORE TRUNCATE ON public.miner_runs_v3
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_miner_runs_v3_no_truncate();

--------------------------------------------------------------- (4) index -----
-- Serves the only two reads this table has: "the latest run of miner X" and
-- "show me last week's batch". D5 — indexes serve queries, not schemas.
CREATE INDEX IF NOT EXISTS idx_miner_runs_v3_miner_started
  ON public.miner_runs_v3 (miner, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_miner_runs_v3_batch
  ON public.miner_runs_v3 (batch_id);

----------------------------------------------------------------- (5) RLS -----
ALTER TABLE public.miner_runs_v3 ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mr_v3_select ON public.miner_runs_v3;
CREATE POLICY mr_v3_select ON public.miner_runs_v3
  FOR SELECT TO authenticated USING (true);

-- ⛔ S-140: the default grant is PER-ROLE and EXPLICIT. `REVOKE ALL … FROM
--    PUBLIC` removes nothing. Name every role, then grant back.
REVOKE ALL ON TABLE public.miner_runs_v3 FROM PUBLIC;
REVOKE ALL ON TABLE public.miner_runs_v3 FROM anon;
REVOKE ALL ON TABLE public.miner_runs_v3 FROM authenticated;
GRANT SELECT ON TABLE public.miner_runs_v3 TO authenticated;
GRANT ALL    ON TABLE public.miner_runs_v3 TO service_role;

-- Target relacl, matching picker_weight_proposals_v3 / feedback_ledger_v3 (S-104):
--   {postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres,authenticated=r/postgres}
