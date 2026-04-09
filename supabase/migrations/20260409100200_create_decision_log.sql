-- CC-05: Create decision_log table for refill engine learning loop
-- Note: plan_line_id and outcome_dispatch_id have NO FK constraints yet —
-- target schemas (refill_plan_output, refill_dispatching) will stabilise in later phases.

CREATE TYPE public.refill_decision_reason AS ENUM (
  'disagree_with_logic',
  'stock_unavailable',
  'logistics_constraint',
  'test_override',
  'one_off_business_reason',
  'other'
);

CREATE TABLE public.decision_log (
  decision_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id                  uuid NOT NULL,
  run_timestamp           timestamptz NOT NULL DEFAULT now(),
  engine_name             text NOT NULL,
  machine_id              uuid REFERENCES public.machines(machine_id),
  pod_product_id          uuid REFERENCES public.pod_products(pod_product_id),
  plan_line_id            uuid,
  inputs_json             jsonb NOT NULL,
  decision_json           jsonb NOT NULL,
  operator_action         text,
  operator_reason         public.refill_decision_reason,
  operator_notes          text,
  outcome_dispatch_id     uuid,
  created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_decision_log_run_id   ON public.decision_log(run_id);
CREATE INDEX idx_decision_log_machine  ON public.decision_log(machine_id, run_timestamp DESC);
CREATE INDEX idx_decision_log_engine   ON public.decision_log(engine_name, run_timestamp DESC);
CREATE INDEX idx_decision_log_reason   ON public.decision_log(operator_reason)
  WHERE operator_reason IS NOT NULL;

ALTER TABLE public.decision_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "decision_log_read_authenticated"
  ON public.decision_log FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "decision_log_write_service_role"
  ON public.decision_log FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

COMMENT ON TABLE public.decision_log IS
'Every refill engine decision captured for learning loop. See refill_engine_bible_v4.html for reason code semantics.';

COMMENT ON COLUMN public.decision_log.engine_name IS
'engine_1 | engine_2 | engine_a | engine_b | engine_c | engine_d | engine_e | layer_1 | step_2';
COMMENT ON COLUMN public.decision_log.plan_line_id IS
'FK to refill_plan_output added later when schema stabilises. Nullable for now.';
COMMENT ON COLUMN public.decision_log.operator_action IS
'NULL until /refill review: accepted | overridden | rejected';
COMMENT ON COLUMN public.decision_log.outcome_dispatch_id IS
'FK to refill_dispatching.dispatch_id, set by field team workflow. No FK constraint yet.';
