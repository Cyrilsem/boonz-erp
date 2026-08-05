-- =====================================================================
-- PRD-110 P3.6 — EDITS AS EVENTS (WS-E2)
-- =====================================================================
-- BUILD-SPEC line 94: plan_edits(plan_date, shelf_id, pod_product_id, kind,
-- qty, lock enum(hard,soft), author, reason); engines compose a base plan then
-- apply the edit overlay; re-runs NEVER drop the overlay.
--
-- ⛔ LAW 3 names the versioning convention (`*_v3`), so the object is
--    plan_edits_v3; the spec line is naming the shape, not the identifier.
-- ⛔ LAW 4: this is SHADOW work. The composer reads and writes
--    pod_refills_shadow only. It never touches refill_plan_output, pod_refills
--    or machines_to_visit.
--
-- THE OVERLAY RULE, stated once:
--   hard  — the human's number wins, permanently, for that plan_date. An engine
--           re-run cannot move it. This is the anti-pattern killer.
--   soft  — the human's number wins only while the engine still believes what
--           it believed WHEN THE EDIT WAS MADE. If the base has moved since,
--           the engine's newer information wins and the edit YIELDS -- but the
--           yield is counted and named in the return value. It is never silent.
--           (This is why base_qty_at_edit exists: an event records what it was
--           reacting to, or "has the base moved?" is unanswerable.)
--   Neither lock can DROP an edit: applied + yielded = considered, asserted.

-- ---------------------------------------------------------------------
-- 1. THE LEDGER
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.plan_edits_v3 (
  edit_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date         date        NOT NULL,
  machine_id        uuid        NOT NULL,
  shelf_id          uuid        NOT NULL,
  pod_product_id    uuid        NOT NULL,
  kind              text        NOT NULL,
  qty               integer,
  "lock"            text        NOT NULL DEFAULT 'soft',
  author            uuid,
  reason            text        NOT NULL,
  base_qty_at_edit  integer,
  source_run_id     uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  superseded_at     timestamptz,
  -- ⛔ DEFERRABLE is load-bearing, not decoration. ux_plan_edits_v3_active
  --    permits exactly one active row per key, so a new edit cannot be inserted
  --    while its predecessor is still active: the supersession UPDATE must come
  --    FIRST, which means superseded_by points at a row that does not exist yet
  --    until the INSERT lands later in the same transaction.
  superseded_by     uuid REFERENCES public.plan_edits_v3(edit_id)
                      DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT chk_plan_edits_v3_kind  CHECK (kind IN ('set_qty','add','drop')),
  CONSTRAINT chk_plan_edits_v3_lock  CHECK ("lock" IN ('hard','soft')),
  -- a drop carries no quantity; anything else must carry a non-negative one
  CONSTRAINT chk_plan_edits_v3_qty   CHECK (
      (kind = 'drop'                AND qty IS NULL)
   OR (kind IN ('set_qty','add')    AND qty IS NOT NULL AND qty >= 0)),
  CONSTRAINT chk_plan_edits_v3_reason CHECK (char_length(btrim(reason)) >= 10),
  CONSTRAINT chk_plan_edits_v3_supersede CHECK (
      (superseded_at IS NULL AND superseded_by IS NULL) OR superseded_at IS NOT NULL)
);

-- ⭐ "exactly one active edit per key" is a STRUCTURAL guarantee, not writer
--    discipline. A second concurrent writer cannot create a duplicate overlay.
CREATE UNIQUE INDEX IF NOT EXISTS ux_plan_edits_v3_active
  ON public.plan_edits_v3 (plan_date, shelf_id, pod_product_id)
  WHERE superseded_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_plan_edits_v3_date ON public.plan_edits_v3 (plan_date);

COMMENT ON TABLE public.plan_edits_v3 IS
  'PRD-110 P3.6. Append-only ledger of human plan edits, consumed as an overlay by compose_plan_with_edits_v3. An engine re-run composes a fresh base and re-applies this overlay, so a re-run can never silently revert a human decision.';

-- ---------------------------------------------------------------------
-- 2. APPEND-ONLY. An edit ledger that can be rewritten in place is not an
--    event log -- it is a scratchpad, and the audit value is gone.
--    Only the supersession columns may ever move.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_plan_edits_v3_append_only()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  -- ⛔ Cody, Article 7: a row-level trigger never sees a TRUNCATE, and
  --    GRANT ALL TO service_role carries TRUNCATE. Without this branch the
  --    "append-only" ledger could be emptied in one statement.
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'plan_edits_v3 is append-only: TRUNCATE refused';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'plan_edits_v3 is append-only: DELETE refused (edit_id %)', OLD.edit_id;
  END IF;
  IF (NEW.edit_id, NEW.plan_date, NEW.machine_id, NEW.shelf_id, NEW.pod_product_id,
      NEW.kind, NEW.qty, NEW."lock", NEW.author, NEW.reason,
      NEW.base_qty_at_edit, NEW.source_run_id, NEW.created_at)
     IS DISTINCT FROM
     (OLD.edit_id, OLD.plan_date, OLD.machine_id, OLD.shelf_id, OLD.pod_product_id,
      OLD.kind, OLD.qty, OLD."lock", OLD.author, OLD.reason,
      OLD.base_qty_at_edit, OLD.source_run_id, OLD.created_at)
  THEN
    RAISE EXCEPTION 'plan_edits_v3 is append-only: only superseded_at/superseded_by may change (edit_id %)', OLD.edit_id;
  END IF;
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS tg_plan_edits_v3_append_only ON public.plan_edits_v3;
CREATE TRIGGER tg_plan_edits_v3_append_only
  BEFORE UPDATE OR DELETE ON public.plan_edits_v3
  FOR EACH ROW EXECUTE FUNCTION public.tg_plan_edits_v3_append_only();

DROP TRIGGER IF EXISTS tg_plan_edits_v3_no_truncate ON public.plan_edits_v3;
CREATE TRIGGER tg_plan_edits_v3_no_truncate
  BEFORE TRUNCATE ON public.plan_edits_v3
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_plan_edits_v3_append_only();

-- ---------------------------------------------------------------------
-- 3. THE ACTIVE OVERLAY
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_plan_edits_active_v3 AS
  SELECT * FROM public.plan_edits_v3 WHERE superseded_at IS NULL;

COMMENT ON VIEW public.v_plan_edits_active_v3 IS
  'PRD-110 P3.6. The current overlay: one row per (plan_date, shelf_id, pod_product_id), enforced by ux_plan_edits_v3_active rather than by convention.';

-- ---------------------------------------------------------------------
-- 4. GRANTS. ⛔ S-88/S-104: the GRANT is the write guard, not RLS, and
--    Supabase default privileges hand new public tables to anon at CREATE.
--    Mirror the ratified sibling facing_proposals_v3 exactly.
-- ---------------------------------------------------------------------
ALTER TABLE public.plan_edits_v3 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.plan_edits_v3        FROM PUBLIC, anon;
REVOKE ALL ON public.v_plan_edits_active_v3 FROM PUBLIC, anon;
GRANT SELECT ON public.plan_edits_v3        TO authenticated;
GRANT SELECT ON public.v_plan_edits_active_v3 TO authenticated;
GRANT ALL    ON public.plan_edits_v3        TO service_role;
GRANT SELECT ON public.v_plan_edits_active_v3 TO service_role;

DROP POLICY IF EXISTS pe_v3_select ON public.plan_edits_v3;
CREATE POLICY pe_v3_select ON public.plan_edits_v3 FOR SELECT USING (true);

-- ---------------------------------------------------------------------
-- 5. THE WRITER
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_plan_edit_v3(
  p_plan_date      date,
  p_shelf_id       uuid,
  p_pod_product_id uuid,
  p_kind           text,
  p_qty            integer,
  p_lock           text,
  p_reason         text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id  uuid;
  v_machine  uuid;
  v_base_run uuid;
  v_base_qty int;
  v_prior    uuid;
  v_edit_id  uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                 true);
  PERFORM set_config('app.rpc_name', 'record_plan_edit_v3',  true);

  -- Role gate, identical in shape to stitch_v3 / record_blocked_demand_v3.
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'record_plan_edit_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL OR p_shelf_id IS NULL OR p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'record_plan_edit_v3: plan_date, shelf_id and pod_product_id are all required';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('set_qty','add','drop') THEN
    RAISE EXCEPTION 'record_plan_edit_v3: kind % is not one of set_qty/add/drop', COALESCE(p_kind,'<null>');
  END IF;
  IF COALESCE(p_lock,'soft') NOT IN ('hard','soft') THEN
    RAISE EXCEPTION 'record_plan_edit_v3: lock % is not one of hard/soft', p_lock;
  END IF;
  -- An edit without a real reason is an edit nobody can review later.
  IF p_reason IS NULL OR char_length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'record_plan_edit_v3: reason must be at least 10 characters (got %)',
      COALESCE(char_length(btrim(p_reason)), 0);
  END IF;
  IF p_kind = 'drop' AND p_qty IS NOT NULL THEN
    RAISE EXCEPTION 'record_plan_edit_v3: a drop carries no quantity';
  END IF;
  IF p_kind IN ('set_qty','add') AND (p_qty IS NULL OR p_qty < 0) THEN
    RAISE EXCEPTION 'record_plan_edit_v3: % requires a non-negative qty', p_kind;
  END IF;

  -- ⛔ DATA-SOURCE LAW: the shelf->machine identity comes from v_shelf_state
  --    (which resolves slot_lifecycle by shelf_id), never by shelf_code.
  SELECT vs.machine_id INTO v_machine
    FROM public.v_shelf_state vs WHERE vs.shelf_id = p_shelf_id LIMIT 1;
  IF v_machine IS NULL THEN
    RAISE EXCEPTION 'record_plan_edit_v3: shelf % resolves to no machine in v_shelf_state', p_shelf_id;
  END IF;

  -- ⭐ The base the human was reacting to. ⛔ It must EXCLUDE composed runs, or
  --    the overlay would measure itself and every soft edit would look fresh.
  SELECT s.run_id INTO v_base_run
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = p_plan_date AND s.engine_tag <> 'compose_v3'
   ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;

  SELECT COALESCE(SUM(s.qty), 0)::int INTO v_base_qty
    FROM public.pod_refills_shadow s
   WHERE s.run_id = v_base_run AND s.shelf_id = p_shelf_id
     AND s.pod_product_id = p_pod_product_id;

  -- Supersede the prior active edit on this key rather than deleting it: both
  -- events stay in the ledger, and the unique partial index keeps exactly one
  -- of them active.
  SELECT e.edit_id INTO v_prior
    FROM public.plan_edits_v3 e
   WHERE e.plan_date = p_plan_date AND e.shelf_id = p_shelf_id
     AND e.pod_product_id = p_pod_product_id AND e.superseded_at IS NULL
   FOR UPDATE;

  -- ⛔ ORDER IS LOAD-BEARING. ux_plan_edits_v3_active allows one active row per
  --    key, so the predecessor must be retired BEFORE the successor is inserted;
  --    insert-first raises a duplicate-key error every time a key is re-edited.
  --    The id is minted up front so the supersession can point forward, which is
  --    what the DEFERRABLE self-FK exists to permit.
  v_edit_id := gen_random_uuid();

  IF v_prior IS NOT NULL THEN
    UPDATE public.plan_edits_v3
       SET superseded_at = now(), superseded_by = v_edit_id
     WHERE edit_id = v_prior;
  END IF;

  INSERT INTO public.plan_edits_v3
    (edit_id, plan_date, machine_id, shelf_id, pod_product_id, kind, qty, "lock",
     author, reason, base_qty_at_edit, source_run_id)
  VALUES
    (v_edit_id, p_plan_date, v_machine, p_shelf_id, p_pod_product_id, p_kind, p_qty,
     COALESCE(p_lock,'soft'), v_user_id, btrim(p_reason), COALESCE(v_base_qty,0), v_base_run);

  RETURN jsonb_build_object(
    'status','ok', 'edit_id', v_edit_id, 'plan_date', p_plan_date,
    'machine_id', v_machine, 'shelf_id', p_shelf_id, 'pod_product_id', p_pod_product_id,
    'kind', p_kind, 'qty', p_qty, 'lock', COALESCE(p_lock,'soft'),
    'base_qty_at_edit', COALESCE(v_base_qty,0), 'source_run_id', v_base_run,
    'superseded_edit_id', v_prior);
END
$fn$;

COMMENT ON FUNCTION public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text) IS
  'PRD-110 P3.6. Records one human plan edit as an event. Captures base_qty_at_edit from the latest NON-composed shadow run so a soft edit can later tell whether the engine has learned anything new. Supersedes any prior active edit on the same key.';

-- ---------------------------------------------------------------------
-- 6. THE COMPOSER — base plan, then overlay.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compose_plan_with_edits_v3(
  p_plan_date     date,
  p_source_run_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id   uuid;
  v_run_id    uuid := gen_random_uuid();
  v_base_run  uuid;
  v_t0        timestamptz := clock_timestamp();
  e           record;
  v_considered int := 0;
  v_applied    int := 0;
  v_yielded    int := 0;
  v_applied_j  jsonb := '[]'::jsonb;
  v_yielded_j  jsonb := '[]'::jsonb;
  v_base_qty   int;
  v_has_base   boolean;
  v_eff        int;
  v_lines_base int := 0;
  v_lines_out  int := 0;
  v_units_base int := 0;
  v_units_out  int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                       true);
  PERFORM set_config('app.rpc_name', 'compose_plan_with_edits_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'compose_plan_with_edits_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'compose_plan_with_edits_v3: p_plan_date is required';
  END IF;

  IF p_source_run_id IS NOT NULL THEN
    SELECT s.run_id INTO v_base_run FROM public.pod_refills_shadow s
     WHERE s.run_id = p_source_run_id AND s.plan_date = p_plan_date LIMIT 1;
    IF v_base_run IS NULL THEN
      RAISE EXCEPTION 'compose_plan_with_edits_v3: source run % has no rows on plan_date %',
        p_source_run_id, p_plan_date;
    END IF;
  ELSE
    -- ⛔ never compose over a previous COMPOSED run: the overlay would be
    --    applied to its own output and every soft edit would read as fresh.
    SELECT s.run_id INTO v_base_run FROM public.pod_refills_shadow s
     WHERE s.plan_date = p_plan_date AND s.engine_tag <> 'compose_v3'
     ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;
  END IF;

  IF v_base_run IS NULL THEN
    RETURN jsonb_build_object(
      'status','no_source_run', 'plan_date', p_plan_date, 'run_id', NULL,
      'note','no non-composed pod_refills_shadow run exists for this plan_date',
      'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
  END IF;

  SELECT count(*), COALESCE(SUM(qty),0) INTO v_lines_base, v_units_base
    FROM public.pod_refills_shadow WHERE run_id = v_base_run;

  -- ⭐ considered is counted INDEPENDENTLY of the loops that consume it. If a
  --    base run ever carried two rows for one (shelf, pod), the loop below
  --    would process one edit twice and the accounting assertion at the end
  --    would RAISE -- which is the point. A counter incremented inside the
  --    loop would have absorbed the duplicate and stayed silently green.
  SELECT count(*) INTO v_considered
    FROM public.v_plan_edits_active_v3 WHERE plan_date = p_plan_date;

  ----------------------------------------------------------------------
  -- (a) BASE LINES, each asked whether an active edit speaks for it.
  ----------------------------------------------------------------------
  FOR e IN
    SELECT b.shelf_id, b.pod_product_id, b.machine_id, b.qty AS base_qty,
           b.current_stock, b.max_stock, b.days_cover, b.signal,
           b.wh_available_pod, b.velocity_instock, b.availability_basis, b.reasoning,
           x.edit_id, x.kind, x.qty AS edit_qty, x."lock" AS lck,
           x.base_qty_at_edit, x.reason
      FROM public.pod_refills_shadow b
      LEFT JOIN public.v_plan_edits_active_v3 x
             ON x.plan_date = p_plan_date
            AND x.shelf_id = b.shelf_id
            AND x.pod_product_id = b.pod_product_id
     WHERE b.run_id = v_base_run
     ORDER BY b.shelf_id, b.pod_product_id
  LOOP
    v_eff := e.base_qty;

    IF e.edit_id IS NOT NULL THEN
      -- hard: the human wins outright. soft: only while the base has not moved.
      IF e.lck = 'hard' OR COALESCE(e.base_qty_at_edit, 0) = e.base_qty THEN
        v_eff := CASE WHEN e.kind = 'drop' THEN 0 ELSE e.edit_qty END;
        v_applied := v_applied + 1;
        v_applied_j := v_applied_j || jsonb_build_object(
          'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
          'kind', e.kind, 'lock', e.lck, 'base_qty', e.base_qty, 'effective_qty', v_eff,
          'reason', e.reason);
      ELSE
        -- ⭐ LAW 5 in the EDIT dimension: a yielded edit is counted and named.
        v_yielded := v_yielded + 1;
        v_yielded_j := v_yielded_j || jsonb_build_object(
          'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
          'kind', e.kind, 'lock', e.lck,
          'base_qty_at_edit', e.base_qty_at_edit, 'base_qty_now', e.base_qty,
          'edit_qty', e.edit_qty, 'effective_qty', v_eff,
          'why','soft edit yielded: the base moved since the edit was recorded');
      END IF;
    END IF;

    IF v_eff > 0 THEN
      INSERT INTO public.pod_refills_shadow
        (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
         current_stock, max_stock, days_cover, signal, wh_available_pod,
         velocity_instock, availability_basis, reasoning)
      VALUES
        (v_run_id, 'compose_v3', p_plan_date, e.machine_id, e.shelf_id, e.pod_product_id, v_eff,
         e.current_stock, e.max_stock, e.days_cover, e.signal, e.wh_available_pod,
         e.velocity_instock, e.availability_basis,
         COALESCE(e.reasoning,'{}'::jsonb) || jsonb_build_object(
           'compose_v3', jsonb_build_object(
             'base_run_id', v_base_run, 'base_qty', e.base_qty,
             'edit_id', e.edit_id, 'edit_kind', e.kind, 'edit_lock', e.lck,
             'overlay', CASE WHEN e.edit_id IS NULL THEN 'none'
                             WHEN v_eff = e.base_qty AND e.lck='soft'
                                  AND COALESCE(e.base_qty_at_edit,0) <> e.base_qty THEN 'yielded'
                             ELSE 'applied' END)));
      v_lines_out := v_lines_out + 1;
      v_units_out := v_units_out + v_eff;
    END IF;
  END LOOP;

  ----------------------------------------------------------------------
  -- (b) EDITS WITH NO BASE LINE. The engine did not plan this shelf at all;
  --     the human says it should be planned. base_qty_now is 0.
  ----------------------------------------------------------------------
  FOR e IN
    SELECT x.edit_id, x.machine_id, x.shelf_id, x.pod_product_id, x.kind,
           x.qty AS edit_qty, x."lock" AS lck, x.base_qty_at_edit, x.reason
      FROM public.v_plan_edits_active_v3 x
     WHERE x.plan_date = p_plan_date
       AND NOT EXISTS (
         SELECT 1 FROM public.pod_refills_shadow b
          WHERE b.run_id = v_base_run AND b.shelf_id = x.shelf_id
            AND b.pod_product_id = x.pod_product_id)
     ORDER BY x.shelf_id, x.pod_product_id
  LOOP
    IF e.kind = 'drop' THEN
      -- dropping a line the base never produced is a satisfied intent, not a gap
      v_applied := v_applied + 1;
      v_applied_j := v_applied_j || jsonb_build_object(
        'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
        'kind', e.kind, 'lock', e.lck, 'base_qty', 0, 'effective_qty', 0,
        'note','drop on a shelf the base did not plan: already satisfied');
      CONTINUE;
    END IF;

    IF e.lck = 'hard' OR COALESCE(e.base_qty_at_edit, 0) = 0 THEN
      v_applied := v_applied + 1;
      v_applied_j := v_applied_j || jsonb_build_object(
        'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
        'kind', e.kind, 'lock', e.lck, 'base_qty', 0, 'effective_qty', e.edit_qty,
        'reason', e.reason);

      IF e.edit_qty > 0 THEN
        -- ⛔ scalar lookups, not a join: if v_shelf_state ever carried two rows
        --    for one shelf, a LEFT JOIN here would insert the line twice.
        INSERT INTO public.pod_refills_shadow
          (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
           current_stock, max_stock, wh_available_pod, availability_basis, reasoning)
        VALUES
          (v_run_id, 'compose_v3', p_plan_date, e.machine_id, e.shelf_id,
           e.pod_product_id, e.edit_qty,
           COALESCE((SELECT vs.current_stock FROM public.v_shelf_state vs
                      WHERE vs.shelf_id = e.shelf_id LIMIT 1), 0),
           COALESCE((SELECT vs.max_stock FROM public.v_shelf_state vs
                      WHERE vs.shelf_id = e.shelf_id LIMIT 1), 0),
           0,
           COALESCE((SELECT CASE WHEN vs.sourcing IN ('boonz_wh','venue','partner','mixed')
                                 THEN vs.sourcing ELSE 'boonz_wh' END
                       FROM public.v_shelf_state vs WHERE vs.shelf_id = e.shelf_id LIMIT 1),
                    'boonz_wh'),
           jsonb_build_object('compose_v3', jsonb_build_object(
             'base_run_id', v_base_run, 'base_qty', 0,
             'edit_id', e.edit_id, 'edit_kind', e.kind, 'edit_lock', e.lck,
             'overlay','applied',
             'note','line introduced by a human edit; the base plan had none')));
        v_lines_out := v_lines_out + 1;
        v_units_out := v_units_out + e.edit_qty;
      END IF;
    ELSE
      v_yielded := v_yielded + 1;
      v_yielded_j := v_yielded_j || jsonb_build_object(
        'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
        'kind', e.kind, 'lock', e.lck,
        'base_qty_at_edit', e.base_qty_at_edit, 'base_qty_now', 0,
        'edit_qty', e.edit_qty, 'effective_qty', 0,
        'why','soft edit yielded: the base dropped this line after the edit was recorded');
    END IF;
  END LOOP;

  -- ⛔ No edit may vanish. If this raises, the overlay lost a human decision,
  --    which is the exact failure P3.6 exists to make impossible.
  IF v_applied + v_yielded <> v_considered THEN
    RAISE EXCEPTION 'compose_plan_with_edits_v3: edit accounting violated - considered=% applied=% yielded=%',
      v_considered, v_applied, v_yielded;
  END IF;

  RETURN jsonb_build_object(
    'status','ok', 'plan_date', p_plan_date, 'run_id', v_run_id,
    'source_run_id', v_base_run, 'engine_tag','compose_v3',
    'lines_base', v_lines_base, 'lines_out', v_lines_out,
    'units_base', v_units_base, 'units_out', v_units_out,
    'edits_considered', v_considered, 'edits_applied', v_applied,
    'edits_yielded', v_yielded,
    'applied', v_applied_j, 'yielded', v_yielded_j,
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
END
$fn$;

COMMENT ON FUNCTION public.compose_plan_with_edits_v3(date,uuid) IS
  'PRD-110 P3.6. Composes a base shadow run with the active plan_edits_v3 overlay into a NEW compose_v3 run. Re-runs never drop the overlay: hard edits outrank a moved base, soft edits yield to it and are reported. applied + yielded = considered is asserted.';

-- ⛔ S-104: the ACL is a fleet convention. REVOKE FROM PUBLIC does not remove
--    the EXECUTE that Supabase default privileges grant to authenticated at
--    CREATE; the line that matters is anon.
REVOKE ALL ON FUNCTION public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.compose_plan_with_edits_v3(date,uuid)                      FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.compose_plan_with_edits_v3(date,uuid)                      TO authenticated, service_role;
