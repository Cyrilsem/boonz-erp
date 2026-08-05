SET LOCAL statement_timeout = '600s';

-- ============================================================================
-- PRD-110 P4.3a — WS-H2 edit-history miner.
--
-- Mines the two edit-history sources for RECURRING human overrides and turns
-- the ones it can honestly target into gated pin proposals, through the
-- canonical P4.1 verbs (submit_feedback_v3 -> propose_pin_from_feedback_v3).
-- It writes nothing to feedback_proposals_v3 itself: that table keeps exactly
-- one writer.
--
-- Sources (charter H1):
--   plan_edits_v3        - the v3-native edits-as-events table (P3.6). Carries
--                          base_qty_at_edit, so direction is exact.
--   pod_refill_plan_audit- the legacy before/after ledger. 1710 rows back to
--                          2026-05-19; this is the "months of labeled training
--                          data" the charter counts on.
--
-- ⛔ WHAT IT WILL NOT DO (each of these is a defect it would be easy to ship):
--
--  1. It will not turn a TRIM into a floor. protect_depth and min_facing are
--     FLOORS; there is no ceiling pin kind. CS cutting Zigi 10 -> 7 three times
--     means "stop sending 10", and the only pin available would pin it AT 10 -
--     the exact inversion of the request. Trims are reported, never proposed.
--  2. It will not emit never_stock. S-128(b) refuses never_stock at approve, so
--     every such proposal would be dead on arrival and would drag G12's
--     acceptance rate down while measuring nothing.
--  3. It will not invent a product. Edit history is at POD grain; pins are at
--     BOONZ PRODUCT grain. When a pod resolves to anything other than exactly
--     one active boonz product for that machine, the cluster is reported, not
--     guessed at. On live data this is the DOMINANT outcome (88 of 100
--     clusters) and it is raised as D-39, not papered over.
--  4. It will not count three edits on one plan_date as three pieces of
--     evidence. Recurrence is measured in DISTINCT plan_dates - occasions on
--     which CS reached the same conclusion independently.
--  5. It will not learn from an unexplained or self-corrected edit (H3):
--     reason must be >= 10 chars, and a superseded plan_edits_v3 row is an edit
--     the author themselves took back.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mine_edit_history_v3(
  p_plan_date       date    DEFAULT NULL,
  p_lookback_days   integer DEFAULT 90,
  p_min_occurrences integer DEFAULT 2,
  p_machine_id      uuid    DEFAULT NULL,
  p_limit           integer DEFAULT 25,
  p_dry_run         boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid         uuid;
  v_role        text;
  v_pd          date;
  v_from        date;
  v_c           record;
  v_fb          jsonb;
  v_pr          jsonb;
  v_fb_id       uuid;
  v_intent      text;
  v_note        text;
  v_trigger     text;
  v_proposals   jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_n_prop      int   := 0;
  v_n_skip      int   := 0;
  v_n_clusters  int   := 0;
  v_n_rows      int   := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                   true);
  PERFORM set_config('app.rpc_name', 'mine_edit_history_v3',   true);

  -- ---- Article 4 role gate, mirroring its P4.1 siblings ----
  v_uid := auth.uid();
  IF v_uid IS NOT NULL THEN
    SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin') THEN
      RAISE EXCEPTION 'mine_edit_history_v3: caller % with role % is not permitted to mine proposals',
        v_uid, COALESCE(v_role,'<none>');
    END IF;
  END IF;

  v_pd := COALESCE(p_plan_date, current_date);
  IF p_lookback_days IS NULL OR p_lookback_days < 1 THEN
    RAISE EXCEPTION 'mine_edit_history_v3: lookback_days must be at least 1 (got %)',
      COALESCE(p_lookback_days::text,'<null>');
  END IF;
  -- ⛔ One occasion is not a pattern. Allowing 1 would turn every single CS edit
  --    into a standing pin proposal and bury the queue.
  IF p_min_occurrences IS NULL OR p_min_occurrences < 2 THEN
    RAISE EXCEPTION 'mine_edit_history_v3: min_occurrences must be at least 2 - one edit is not a recurrence (got %)',
      COALESCE(p_min_occurrences::text,'<null>');
  END IF;
  IF p_limit IS NULL OR p_limit < 1 THEN
    RAISE EXCEPTION 'mine_edit_history_v3: limit must be at least 1 (got %)',
      COALESCE(p_limit::text,'<null>');
  END IF;
  IF p_machine_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.machines m WHERE m.machine_id = p_machine_id) THEN
    RAISE EXCEPTION 'mine_edit_history_v3: machine % not found', p_machine_id;
  END IF;

  v_from := v_pd - p_lookback_days;

  -- ⛔ S-101: ON COMMIT DROP is not ON RETURN DROP. Two calls in one transaction
  --    (the fixture does exactly that) would collide on the leftover table.
  DROP TABLE IF EXISTS _mine_clusters;
  CREATE TEMP TABLE _mine_clusters ON COMMIT DROP AS
  WITH stream AS (
    -- v3-native edits. superseded_at IS NULL is the machine-readable "the author
    -- took this back" filter H3 asks for; free-text reasons cannot supply one.
    SELECT e.machine_id, e.shelf_id, e.pod_product_id, e.plan_date,
           CASE WHEN e.kind = 'drop' THEN 0 ELSE e.qty END AS to_qty,
           e.base_qty_at_edit                              AS from_qty,
           'plan_edits_v3'::text                           AS src
      FROM public.plan_edits_v3 e
     WHERE e.superseded_at IS NULL
       AND e.plan_date >= v_from AND e.plan_date < v_pd
       AND e.machine_id IS NOT NULL AND e.shelf_id IS NOT NULL AND e.pod_product_id IS NOT NULL
       AND e.reason IS NOT NULL AND char_length(btrim(e.reason)) >= 10
       AND (p_machine_id IS NULL OR e.machine_id = p_machine_id)
    UNION ALL
    -- Legacy audit. 'reopen' and 'convert' are status transitions, not quantity
    -- preferences, and are deliberately outside the vocabulary.
    SELECT a.machine_id, a.shelf_id, a.pod_product_id, a.plan_date,
           NULLIF(a.after_state ->> 'qty','')::int,
           CASE WHEN a.edit_type = 'add' THEN 0
                ELSE NULLIF(a.before_state ->> 'qty','')::int END,
           'pod_refill_plan_audit'::text
      FROM public.pod_refill_plan_audit a
     WHERE a.edit_type IN ('qty','add','stop')
       AND a.plan_date >= v_from AND a.plan_date < v_pd
       AND a.machine_id IS NOT NULL AND a.shelf_id IS NOT NULL AND a.pod_product_id IS NOT NULL
       AND a.reason IS NOT NULL AND char_length(btrim(a.reason)) >= 10
       -- ⛔ the jsonb is untyped; a non-numeric qty must not abort the whole job
       AND COALESCE(a.after_state ->> 'qty','') ~ '^-?[0-9]+$'
       AND (p_machine_id IS NULL OR a.machine_id = p_machine_id)
  ),
  dir AS (
    SELECT s.*,
           CASE
             WHEN s.to_qty IS NULL                                              THEN 'unknown'
             WHEN COALESCE(s.from_qty,0) = 0 AND s.to_qty > 0                   THEN 'add_missing'
             WHEN s.to_qty = 0 AND COALESCE(s.from_qty,0) > 0                   THEN 'stop'
             WHEN s.from_qty IS NOT NULL AND s.to_qty > s.from_qty              THEN 'raise'
             WHEN s.from_qty IS NOT NULL AND s.to_qty < s.from_qty              THEN 'trim'
             ELSE 'noop'
           END AS direction
      FROM stream s
  )
  SELECT d.machine_id, d.shelf_id, d.pod_product_id, d.direction,
         count(DISTINCT d.plan_date)                                   AS occasions,
         count(*)                                                      AS edit_rows,
         min(d.to_qty)                                                 AS qty_min,
         max(d.to_qty)                                                 AS qty_max,
         GREATEST(1, floor(percentile_cont(0.5) WITHIN GROUP (ORDER BY d.to_qty))::int) AS qty_median,
         string_agg(DISTINCT d.plan_date::text, ', ' ORDER BY d.plan_date::text) AS occasion_dates,
         string_agg(DISTINCT d.src, '+' ORDER BY d.src)                AS sources,
         (SELECT count(DISTINCT pm.boonz_product_id)
            FROM public.product_mapping pm
           WHERE pm.pod_product_id = d.pod_product_id
             AND pm.status = 'Active'
             AND pm.boonz_product_id IS NOT NULL
             -- ⛔ house rule (resolve_fefo_sku_legs_v3): machine-scoped row OR the
             --    global default. NEVER a name match, never a single arbitrary row.
             AND (pm.machine_id = d.machine_id OR pm.machine_id IS NULL))       AS n_boonz,
         (SELECT (array_agg(DISTINCT pm.boonz_product_id))[1]
            FROM public.product_mapping pm
           WHERE pm.pod_product_id = d.pod_product_id
             AND pm.status = 'Active'
             AND pm.boonz_product_id IS NOT NULL
             AND (pm.machine_id = d.machine_id OR pm.machine_id IS NULL))       AS boonz_product_id
    FROM dir d
   WHERE d.direction IN ('add_missing','raise','trim','stop')
   GROUP BY d.machine_id, d.shelf_id, d.pod_product_id, d.direction
  HAVING count(DISTINCT d.plan_date) >= p_min_occurrences;

  SELECT count(*), COALESCE(sum(edit_rows),0) INTO v_n_clusters, v_n_rows FROM _mine_clusters;

  FOR v_c IN
    SELECT c.*,
           CASE c.direction WHEN 'raise' THEN 'protect_depth' WHEN 'add_missing' THEN 'always_stock' END AS pin_kind
      FROM _mine_clusters c
     -- deterministic: strongest evidence first, then a total order on the key
     ORDER BY c.occasions DESC, c.edit_rows DESC,
              c.machine_id::text, c.shelf_id::text, c.pod_product_id::text, c.direction
  LOOP
    -- ---- the four refusals, each named so the receipt explains itself ----
    IF v_c.direction = 'trim' THEN
      v_skipped := v_skipped || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'direction', v_c.direction,
        'occasions', v_c.occasions,
        'reason', 'no_ceiling_pin_kind_exists',
        'detail', 'CS trimmed to a median of ' || v_c.qty_median ||
                  '; every pin kind is a FLOOR, so proposing one would pin the quantity CS was cutting');
      v_n_skip := v_n_skip + 1; CONTINUE;
    END IF;

    IF v_c.direction = 'stop' THEN
      v_skipped := v_skipped || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'direction', v_c.direction,
        'occasions', v_c.occasions,
        'reason', 'never_stock_refused_at_approve_s128b',
        'detail', 'a never_stock proposal cannot be approved while S-128(b) stands, so minting one would only depress G12');
      v_n_skip := v_n_skip + 1; CONTINUE;
    END IF;

    IF v_c.n_boonz <> 1 OR v_c.boonz_product_id IS NULL THEN
      v_skipped := v_skipped || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'direction', v_c.direction,
        'occasions', v_c.occasions,
        'reason', CASE WHEN v_c.n_boonz = 0 THEN 'pod_has_no_active_mapping'
                       ELSE 'pod_maps_to_multiple_boonz_products' END,
        'detail', 'edit history is at POD grain and pins are at BOONZ PRODUCT grain; this pod resolves to ' ||
                  v_c.n_boonz || ' active products on this machine (D-39)',
        'n_boonz', v_c.n_boonz);
      v_n_skip := v_n_skip + 1; CONTINUE;
    END IF;

    -- ---- already known? then nothing was learned ----
    -- ⛔ Article 16: this asks the REGISTERED metric "is a pin currently in force?",
    --    so it reads the canonical view. The base-table allow-list (leg 80) covers
    --    only the two verbs asking the DIFFERENT question "which row occupies the
    --    uniqueness slot?". Re-deriving revoked/expired here would be the exact
    --    divergence Article 16 exists to prevent.
    IF EXISTS (
      SELECT 1 FROM public.v_planning_pins_active_v3 p
       WHERE p.machine_id = v_c.machine_id
         AND p.shelf_id IS NOT DISTINCT FROM v_c.shelf_id
         AND p.boonz_product_id = v_c.boonz_product_id
         AND p.kind = v_c.pin_kind
         AND COALESCE(p.value, 0) >= COALESCE(CASE WHEN v_c.pin_kind = 'protect_depth' THEN v_c.qty_median END, 0)
    ) THEN
      v_skipped := v_skipped || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'direction', v_c.direction,
        'occasions', v_c.occasions, 'reason', 'already_pinned',
        'detail', 'a live ' || v_c.pin_kind || ' pin already covers this target at or above the mined value');
      v_n_skip := v_n_skip + 1; CONTINUE;
    END IF;

    -- ⛔ Idempotency. This is a weekly job; without this guard a second run
    --    supersedes its own pending proposal, spends fresh evidence and churns
    --    the queue while learning nothing new.
    IF EXISTS (
      SELECT 1 FROM public.feedback_proposals_v3 pr
       WHERE pr.status = 'pending'
         AND pr.machine_id = v_c.machine_id
         AND pr.shelf_id IS NOT DISTINCT FROM v_c.shelf_id
         AND pr.boonz_product_id = v_c.boonz_product_id
         AND pr.pin_kind = v_c.pin_kind
         AND pr.pin_value IS NOT DISTINCT FROM
             CASE WHEN v_c.pin_kind = 'protect_depth' THEN v_c.qty_median END
    ) THEN
      v_skipped := v_skipped || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'direction', v_c.direction,
        'occasions', v_c.occasions, 'reason', 'already_pending_identical',
        'detail', 'an identical proposal is already waiting for CS');
      v_n_skip := v_n_skip + 1; CONTINUE;
    END IF;

    IF v_n_prop >= p_limit THEN
      -- ⛔ NO SILENT CAP: what the limit dropped is named, not omitted.
      v_skipped := v_skipped || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'direction', v_c.direction,
        'occasions', v_c.occasions, 'reason', 'over_limit',
        'detail', 'p_limit of ' || p_limit || ' reached; re-run to pick this up');
      v_n_skip := v_n_skip + 1; CONTINUE;
    END IF;

    v_intent  := CASE v_c.direction WHEN 'raise' THEN 'dont_reduce' ELSE 'always_stock' END;
    v_note    := 'edit-history miner (WS-H2): CS applied a ' || v_c.direction ||
                 ' to this pod on ' || v_c.occasions || ' distinct plan dates (' || v_c.occasion_dates ||
                 ') across ' || v_c.edit_rows || ' explained edits from ' || v_c.sources ||
                 '; edited quantity min/median/max ' || v_c.qty_min || '/' || v_c.qty_median || '/' || v_c.qty_max || '.';
    v_trigger := 'WS-H2 recurring ' || v_c.direction || ' on ' || v_c.occasions ||
                 ' distinct plan dates within ' || p_lookback_days || ' days; proposing ' ||
                 v_c.pin_kind ||
                 CASE WHEN v_c.pin_kind = 'protect_depth' THEN ' at depth ' || v_c.qty_median ELSE '' END || '.';

    IF p_dry_run THEN
      v_proposals := v_proposals || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'boonz_product_id', v_c.boonz_product_id,
        'direction', v_c.direction, 'pin_kind', v_c.pin_kind,
        'pin_value', CASE WHEN v_c.pin_kind = 'protect_depth' THEN v_c.qty_median END,
        'occasions', v_c.occasions, 'edit_rows', v_c.edit_rows,
        'sources', v_c.sources, 'proposal_id', NULL, 'dry_run', true);
      v_n_prop := v_n_prop + 1;
      CONTINUE;
    END IF;

    BEGIN
      -- Evidence first, through the canonical ledger verb: the 'miner' channel
      -- and its operator_admin/superadmin gate were built for exactly this.
      v_fb := public.submit_feedback_v3(
                'miner', v_c.machine_id, v_intent, v_note, v_c.shelf_id, v_c.boonz_product_id);
      -- ⛔ the inner verb stamped app.rpc_name with its OWN name and both settings
      --    are transaction-local (fixture 56 seq 24). Restore attribution.
      PERFORM set_config('app.via_rpc',  'true',                 true);
      PERFORM set_config('app.rpc_name', 'mine_edit_history_v3', true);

      v_fb_id := (v_fb ->> 'feedback_id')::uuid;
      IF v_fb_id IS NULL THEN
        RAISE EXCEPTION 'submit_feedback_v3 returned no feedback_id (%)', v_fb;
      END IF;

      v_pr := public.propose_pin_from_feedback_v3(
                ARRAY[v_fb_id], v_pd, v_c.pin_kind, v_trigger,
                CASE WHEN v_c.pin_kind = 'protect_depth' THEN v_c.qty_median END,
                'perpetual', NULL);
      PERFORM set_config('app.via_rpc',  'true',                 true);
      PERFORM set_config('app.rpc_name', 'mine_edit_history_v3', true);

      v_proposals := v_proposals || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'boonz_product_id', v_c.boonz_product_id,
        'direction', v_c.direction, 'pin_kind', v_c.pin_kind,
        'pin_value', CASE WHEN v_c.pin_kind = 'protect_depth' THEN v_c.qty_median END,
        'occasions', v_c.occasions, 'edit_rows', v_c.edit_rows, 'sources', v_c.sources,
        'feedback_id', v_fb_id, 'proposal_id', (v_pr ->> 'proposal_id')::uuid, 'dry_run', false);
      v_n_prop := v_n_prop + 1;

    EXCEPTION WHEN OTHERS THEN
      -- One bad cluster must not kill the weekly job. The refusal is recorded
      -- verbatim so it is diagnosable rather than invisible.
      v_skipped := v_skipped || jsonb_build_object(
        'machine_id', v_c.machine_id, 'shelf_id', v_c.shelf_id,
        'pod_product_id', v_c.pod_product_id, 'direction', v_c.direction,
        'occasions', v_c.occasions, 'reason', 'writer_refused',
        'detail', SQLERRM);
      v_n_skip := v_n_skip + 1;
    END;
  END LOOP;

  DROP TABLE IF EXISTS _mine_clusters;

  RETURN jsonb_build_object(
    'status','ok',
    'plan_date',        v_pd,
    'window_from',      v_from,
    'window_to',        v_pd,
    'lookback_days',    p_lookback_days,
    'min_occurrences',  p_min_occurrences,
    'machine_scope',    p_machine_id,
    'dry_run',          COALESCE(p_dry_run,false),
    'clusters_found',   v_n_clusters,
    'edit_rows_mined',  v_n_rows,
    'proposals_made',   v_n_prop,
    'clusters_skipped', v_n_skip,
    'proposals',        v_proposals,
    'skipped',          v_skipped);
END
$fn$;

REVOKE ALL ON FUNCTION public.mine_edit_history_v3(date,integer,integer,uuid,integer,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mine_edit_history_v3(date,integer,integer,uuid,integer,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mine_edit_history_v3(date,integer,integer,uuid,integer,boolean) TO service_role;

COMMENT ON FUNCTION public.mine_edit_history_v3(date,integer,integer,uuid,integer,boolean) IS
'PRD-110 P4.3a WS-H2 edit-history miner. Clusters recurring human overrides in plan_edits_v3 + pod_refill_plan_audit by (machine, shelf, pod, direction), counting DISTINCT plan_dates as occasions, and routes the honestly-targetable ones through submit_feedback_v3(channel=miner) -> propose_pin_from_feedback_v3. Refuses by name: trims (no ceiling pin kind exists - a floor would invert the request), stops (never_stock is refused at approve per S-128(b)), pods that do not resolve to exactly one active boonz product on that machine (D-39), targets already pinned or already pending, and anything past p_limit. Never writes feedback_proposals_v3 directly.';
