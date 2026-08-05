-- PRD-110 · leg 77 · P3.8 — THE FREED-ALLOCATION RE-OFFER
-- Closes fixture 11's RED (17 failures). Purely ADDITIVE (LAW 3): one new table
-- and one new function. No existing engine is touched, so no md5 pin moves (S-122).
--
-- The gap: compose_plan_with_edits_v3 handles a 'drop' by setting the effective
-- qty to 0 and not inserting the line. The warehouse units that line had already
-- claimed simply cease to be claimed, with no record anywhere that they came back.
-- On 2026-07-30 two AMZ machines were dropped post-draft and VML-1004 A05 sat
-- blocked_no_wh on the very product AMZ-1029 A06 had just released.
--
-- This is a PROPOSER, not an allocator (LAW 4): it writes only its own queue,
-- behind the CS gate. It never moves a plan line, never touches a protected table.

SET LOCAL statement_timeout = '180s';

-- ---------------------------------------------------------------------------
-- 1. THE QUEUE
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reallocation_proposals_v3 (
  proposal_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date          date        NOT NULL,
  proposed_at        timestamptz NOT NULL DEFAULT now(),
  base_run_id        uuid        NOT NULL,
  composed_run_id    uuid        NOT NULL,

  -- where the units came back from
  source_machine_id  uuid        NOT NULL REFERENCES public.machines(machine_id),
  source_shelf_id    uuid        NOT NULL REFERENCES public.shelf_configurations(shelf_id),
  pod_product_id     uuid        NOT NULL REFERENCES public.pod_products(pod_product_id),
  freed_qty          integer     NOT NULL,

  -- where they are being offered (NULL only when nothing in this plan can use them)
  target_machine_id  uuid        REFERENCES public.machines(machine_id),
  target_shelf_id    uuid        REFERENCES public.shelf_configurations(shelf_id),
  target_unmet_qty   integer,
  proposed_qty       integer     NOT NULL DEFAULT 0,

  trigger_reason     text        NOT NULL,
  reasoning          jsonb       NOT NULL DEFAULT '{}'::jsonb,

  status             text        NOT NULL DEFAULT 'proposed',
  reviewed_by        uuid,
  reviewed_at        timestamptz,
  review_note        text,

  CONSTRAINT realloc_v3_status_chk
    CHECK (status IN ('proposed','unclaimed','approved','rejected','applied')),
  CONSTRAINT realloc_v3_freed_positive
    CHECK (freed_qty > 0),
  CONSTRAINT realloc_v3_qty_sane
    CHECK (proposed_qty >= 0 AND proposed_qty <= freed_qty),
  -- ⛔ LAW 5 in the RE-ALLOCATION dimension. An unclaimed row is the RECORD that
  --    units came back with nowhere to go; it must name no target and offer
  --    nothing. Every other status must name a real target and a real quantity.
  --    Without this pair a "silent" row could masquerade as either shape.
  CONSTRAINT realloc_v3_unclaimed_is_empty
    CHECK ((status = 'unclaimed') = (target_shelf_id IS NULL)),
  CONSTRAINT realloc_v3_unclaimed_offers_nothing
    CHECK (status <> 'unclaimed' OR (proposed_qty = 0 AND target_machine_id IS NULL)),
  CONSTRAINT realloc_v3_matched_offers_something
    CHECK (status = 'unclaimed' OR (proposed_qty > 0 AND target_machine_id IS NOT NULL)),
  CONSTRAINT realloc_v3_never_self
    CHECK (target_shelf_id IS NULL OR target_shelf_id <> source_shelf_id),
  CONSTRAINT realloc_v3_reason_named
    CHECK (btrim(trigger_reason) <> '')
);

CREATE INDEX IF NOT EXISTS ix_realloc_v3_plan_date
  ON public.reallocation_proposals_v3 (plan_date, status);
CREATE INDEX IF NOT EXISTS ix_realloc_v3_open
  ON public.reallocation_proposals_v3 (plan_date) WHERE reviewed_at IS NULL;
-- one live offer per (source line -> target line) per composed run
CREATE UNIQUE INDEX IF NOT EXISTS ux_realloc_v3_pair
  ON public.reallocation_proposals_v3
     (composed_run_id, source_shelf_id, pod_product_id,
      COALESCE(target_shelf_id, '00000000-0000-0000-0000-000000000000'::uuid));

ALTER TABLE public.reallocation_proposals_v3 ENABLE ROW LEVEL SECURITY;

DO $rls$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='reallocation_proposals_v3'
                    AND policyname='realloc_v3_read_authenticated') THEN
    -- read-only to signed-in staff; the proposer itself is SECURITY DEFINER
    CREATE POLICY realloc_v3_read_authenticated
      ON public.reallocation_proposals_v3 FOR SELECT TO authenticated USING (true);
  END IF;
END
$rls$;

REVOKE ALL ON public.reallocation_proposals_v3 FROM anon;
GRANT SELECT ON public.reallocation_proposals_v3 TO authenticated;

COMMENT ON TABLE public.reallocation_proposals_v3 IS
  'PRD-110 P3.8. Warehouse units freed when a planned line is dropped mid-plan, re-offered '
  'to a shelf in the SAME plan that was blocked on exactly that product. A CS-gated queue: '
  'nothing here moves a plan line. status=unclaimed records freed units nobody could use, so '
  'a freed unit is never silently absorbed (fixture 11).';

-- ---------------------------------------------------------------------------
-- 2. THE PROPOSER
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.propose_reallocations_v3(
  p_plan_date       date,
  p_base_run_id     uuid,
  p_composed_run_id uuid,
  p_dry_run         boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id  uuid;
  v_t0       timestamptz := clock_timestamp();
  v_rows     jsonb := '[]'::jsonb;
  v_written  int := 0;
  v_freed    int := 0;
  v_matched  int := 0;
  v_unclaim  int := 0;
  v_ins      int := 0;
  v_srcs     int := 0;
  v_repr     int := 0;
  r          record;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                     true);
  PERFORM set_config('app.rpc_name', 'propose_reallocations_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'propose_reallocations_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL OR p_base_run_id IS NULL OR p_composed_run_id IS NULL THEN
    RAISE EXCEPTION 'propose_reallocations_v3: plan_date, base_run_id and composed_run_id are all required';
  END IF;
  IF p_base_run_id = p_composed_run_id THEN
    RAISE EXCEPTION 'propose_reallocations_v3: base and composed run must differ (got % twice)', p_base_run_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pod_refills_shadow
                  WHERE run_id = p_base_run_id AND plan_date = p_plan_date) THEN
    RAISE EXCEPTION 'propose_reallocations_v3: base run % has no rows on plan_date %',
      p_base_run_id, p_plan_date;
  END IF;

  ------------------------------------------------------------------------
  -- FREED. A boonz_wh line whose effective quantity fell between the base
  -- draft and the composed plan has handed warehouse units back.
  -- ⛔ Only boonz_wh: venue and partner stock was never a warehouse claim,
  --    so "freeing" it would offer units the warehouse does not have.
  ------------------------------------------------------------------------
  -- ⛔ REVISION (Cody): ON COMMIT DROP is not ON RETURN DROP (S-101). A call that
  --    raises after creating these leaves them behind for the rest of the
  --    transaction, and the next call in that same transaction would fail on
  --    "relation already exists". Drop on the way IN, not only on the way out.
  DROP TABLE IF EXISTS _freed_v3;
  DROP TABLE IF EXISTS _claim_v3;

  CREATE TEMP TABLE _freed_v3 ON COMMIT DROP AS
  SELECT b.machine_id, b.shelf_id, b.pod_product_id,
         (b.qty - COALESCE(c.qty, 0))::int AS freed_qty
    FROM (SELECT machine_id, shelf_id, pod_product_id, SUM(qty)::int AS qty
            FROM public.pod_refills_shadow
           WHERE run_id = p_base_run_id AND availability_basis = 'boonz_wh'
           GROUP BY 1,2,3) b
    LEFT JOIN (SELECT shelf_id, pod_product_id, SUM(qty)::int AS qty
                 FROM public.pod_refills_shadow
                WHERE run_id = p_composed_run_id
                GROUP BY 1,2) c
           ON c.shelf_id = b.shelf_id AND c.pod_product_id = b.pod_product_id
   WHERE (b.qty - COALESCE(c.qty, 0)) > 0;

  SELECT COALESCE(SUM(freed_qty),0) INTO v_freed FROM _freed_v3;

  ------------------------------------------------------------------------
  -- CLAIMANTS. A shelf in the SAME draft that asked for this exact product
  -- and did not get all of it. ⛔ Being merely under-full is NOT a claim --
  -- only an explicit warehouse-shortage clamp is, or this becomes a
  -- rebalancer and starts moving stock nobody asked for.
  -- ⛔ A shelf that itself freed units is not a claimant: its machine was
  --    dropped, so it will not be visited.
  ------------------------------------------------------------------------
  CREATE TEMP TABLE _claim_v3 ON COMMIT DROP AS
  SELECT s.machine_id, s.shelf_id, s.pod_product_id,
         GREATEST(s.max_stock - s.current_stock - s.qty, 0)::int AS unmet,
         GREATEST(s.max_stock - s.current_stock - s.qty, 0)::int AS remaining
    FROM public.pod_refills_shadow s
   WHERE s.run_id = p_base_run_id
     AND s.availability_basis = 'boonz_wh'
     AND s.clamp_reason IN ('blocked_no_wh','partial_wh_limited')
     AND GREATEST(s.max_stock - s.current_stock - s.qty, 0) > 0
     AND NOT EXISTS (SELECT 1 FROM _freed_v3 f WHERE f.shelf_id = s.shelf_id)
     AND NOT EXISTS (SELECT 1 FROM _freed_v3 f WHERE f.machine_id = s.machine_id);

  ------------------------------------------------------------------------
  -- MATCH. Deterministic: largest unmet need first, then shelf_id, so two
  -- runs over the same inputs produce the same queue.
  ------------------------------------------------------------------------
  FOR r IN SELECT * FROM _freed_v3 ORDER BY shelf_id, pod_product_id
  LOOP
    DECLARE
      v_left int := r.freed_qty;
      v_any  boolean := false;
      c      record;
      v_take int;
    BEGIN
      FOR c IN SELECT * FROM _claim_v3
                WHERE pod_product_id = r.pod_product_id AND remaining > 0
                ORDER BY remaining DESC, shelf_id
      LOOP
        EXIT WHEN v_left <= 0;
        v_take := LEAST(v_left, c.remaining);
        CONTINUE WHEN v_take <= 0;

        IF NOT p_dry_run THEN
          INSERT INTO public.reallocation_proposals_v3
            (plan_date, base_run_id, composed_run_id,
             source_machine_id, source_shelf_id, pod_product_id, freed_qty,
             target_machine_id, target_shelf_id, target_unmet_qty, proposed_qty,
             trigger_reason, status, reasoning)
          VALUES
            (p_plan_date, p_base_run_id, p_composed_run_id,
             r.machine_id, r.shelf_id, r.pod_product_id, r.freed_qty,
             c.machine_id, c.shelf_id, c.unmet, v_take,
             'freed_by_plan_drop', 'proposed',
             jsonb_build_object(
               'freed_qty', r.freed_qty, 'offered', v_take,
               'target_unmet', c.unmet,
               'why', 'the source line was dropped from this plan; the target shelf was '
                      'clamped on the same product for want of warehouse stock'))
          ON CONFLICT DO NOTHING;
          -- ⛔ REVISION (Cody): ON CONFLICT DO NOTHING can suppress the row while a
          --    blind counter still claims it was written. Count what Postgres
          --    actually inserted, or a re-run reports writes it never made.
          GET DIAGNOSTICS v_ins = ROW_COUNT;
          v_written := v_written + v_ins;
        END IF;

        v_rows := v_rows || jsonb_build_object(
          'src_shelf', r.shelf_id, 'pod', r.pod_product_id, 'freed', r.freed_qty,
          'tgt_shelf', c.shelf_id, 'qty', v_take, 'status', 'proposed');
        v_matched := v_matched + 1;
        v_any := true;
        v_left := v_left - v_take;
        UPDATE _claim_v3 SET remaining = remaining - v_take WHERE shelf_id = c.shelf_id;
      END LOOP;

      ------------------------------------------------------------------
      -- ⛔ THE POINT OF THE WHOLE FUNCTION. Freed units nobody can use are
      --    RECORDED, not dropped on the floor.
      ------------------------------------------------------------------
      IF NOT v_any THEN
        IF NOT p_dry_run THEN
          INSERT INTO public.reallocation_proposals_v3
            (plan_date, base_run_id, composed_run_id,
             source_machine_id, source_shelf_id, pod_product_id, freed_qty,
             target_machine_id, target_shelf_id, target_unmet_qty, proposed_qty,
             trigger_reason, status, reasoning)
          VALUES
            (p_plan_date, p_base_run_id, p_composed_run_id,
             r.machine_id, r.shelf_id, r.pod_product_id, r.freed_qty,
             NULL, NULL, NULL, 0,
             'freed_by_plan_drop', 'unclaimed',
             jsonb_build_object(
               'freed_qty', r.freed_qty,
               'why', 'the source line was dropped from this plan and no shelf in the same '
                      'plan was clamped on this product, so the units return to the warehouse '
                      'unspoken for'))
          ON CONFLICT DO NOTHING;
          GET DIAGNOSTICS v_ins = ROW_COUNT;
          v_written := v_written + v_ins;
        END IF;
        v_rows := v_rows || jsonb_build_object(
          'src_shelf', r.shelf_id, 'pod', r.pod_product_id, 'freed', r.freed_qty,
          'tgt_shelf', NULL, 'qty', 0, 'status', 'unclaimed');
        v_unclaim := v_unclaim + 1;
      END IF;
    END;
  END LOOP;

  -- ⛔ No freed line may vanish. If this raises, the proposer lost units, which
  --    is the exact failure P3.8 exists to make impossible.
  -- ⛔ REVISION (Cody): the old form compared (matched + unclaimed) against the
  --    freed-line count, but a PAIR count is not a SOURCE count -- one source
  --    split across two claimants scored 2 and could mask a source that was
  --    represented nowhere. Count DISTINCT sources actually represented.
  SELECT count(*) INTO v_srcs FROM _freed_v3;
  SELECT count(DISTINCT (p->>'src_shelf') || '|' || (p->>'pod')) INTO v_repr
    FROM jsonb_array_elements(v_rows) p;
  IF v_repr < v_srcs THEN
    RAISE EXCEPTION 'propose_reallocations_v3: freed-line accounting violated - freed sources=% represented=%',
      v_srcs, v_repr;
  END IF;

  DROP TABLE IF EXISTS _freed_v3;
  DROP TABLE IF EXISTS _claim_v3;

  RETURN jsonb_build_object(
    'status','ok', 'plan_date', p_plan_date, 'dry_run', p_dry_run,
    'base_run_id', p_base_run_id, 'composed_run_id', p_composed_run_id,
    'freed_lines', v_srcs,
    'freed_units', v_freed,
    'proposals', v_matched + v_unclaim,
    'matched', v_matched, 'unclaimed', v_unclaim,
    'rows_written', v_written,
    'detail', v_rows,
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
END
$function$;

REVOKE ALL ON FUNCTION public.propose_reallocations_v3(date,uuid,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.propose_reallocations_v3(date,uuid,uuid,boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.propose_reallocations_v3(date,uuid,uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.propose_reallocations_v3(date,uuid,uuid,boolean) TO service_role;

COMMENT ON FUNCTION public.propose_reallocations_v3(date,uuid,uuid,boolean) IS
  'PRD-110 P3.8. Diffs a base draft against its composed plan, and for every boonz_wh line '
  'whose quantity fell (a mid-plan drop) re-offers the freed units to a shelf in the same plan '
  'that was clamped blocked_no_wh / partial_wh_limited on the same pod_product. Emits an '
  'unclaimed row when nothing can use them. Dry-run computes without writing. Proposes only: '
  'writes nothing but its own CS-gated queue (fixture 11).';
