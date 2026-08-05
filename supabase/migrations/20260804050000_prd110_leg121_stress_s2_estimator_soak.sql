-- PRD-110 leg 121 - STEP 7 / S2: estimator soak, 10 000 synthetic WEIMI deltas.
--
-- WHAT S2 MUST PROVE (goal command STEP 7): "estimator soak: 10k synthetic WEIMI deltas incl.
-- anomaly storm (count>capacity, negative deltas, venue fills) - composition never negative,
-- expired never auto-consumed, confidence bounds hold."
--
-- ── WHY THIS IS A ROLLBACK PROBE ───────────────────────────────────────────────────────────
-- inventory_events is APPEND-ONLY (tg_inventory_events_append_only, BEFORE DELETE OR UPDATE)
-- and held 50 rows at this leg's open; shelf_composition held 31 and inventory_anomalies 147.
-- A 10k-observation soak moves all three permanently and there is no deleter for the first.
-- Persisting 10 000 synthetic rows into an append-only truth table to prove a stress property
-- is exactly what Cody refuses, so S2 runs inside a plpgsql subtransaction that ALWAYS ends in
-- RAISE - the fixture-31 / fixture-8 idiom, now proven six times. Nothing persists.
-- ⛔ S2 therefore consumes NO plan_date: the estimator touches no plan table at all, so the
-- leg-116 reservation of 2030-11-02 is released rather than used.
--
-- ── HOW A SYNTHETIC "WEIMI DELTA" IS MANUFACTURED, AND WHY IT GOES THROUGH THE REAL PATH ───
-- The estimator reads v_shelf_state -> v_shelf_slot_identity -> v_live_shelf_stock ->
-- weimi_device_status.door_statuses (jsonb: cabinets -> layers -> aisles, each aisle carrying
-- showName / currStock / maxStock). v_live_shelf_stock takes DISTINCT ON (device_name) ORDER BY
-- snapshot_at DESC, so a delta is made by appending ONE new weimi_device_status row per device
-- whose door_statuses is the previous jsonb with currStock rewritten per aisle. Nothing about
-- the read path is stubbed or bypassed - the estimator cannot tell the plant from a real poll.
--
-- ⛔ TWO SHAPE CONSTRAINTS THE DESIGN DID NOT HAVE, both measured live this leg:
--   1. unique_device_status UNIQUE (weimi_device_id, snapshot_date) - ONE snapshot per device
--      per CALENDAR DATE. Rounds therefore step by a whole day, not by hours, and they step
--      FORWARD of the latest real snapshot so DISTINCT ON still elects them.
--   2. The latest-per-device_name set is 58 rows but only 41 distinct weimi_device_id: eleven
--      devices carry historical rename aliases (NISSAN-0804 was ACTIVATEMCC-1010, and so on).
--      Keying the plant on device_name puts 17 duplicate device ids into a single INSERT and
--      trips the unique index. The plant keys on weimi_device_id and keeps the newest name.
--
-- ── THE STORM IS ROLE-DRIVEN, NOT HASH-DRIVEN, AND THAT IS DELIBERATE ──────────────────────
-- A modulo-of-a-hash storm looks rigorous and proves nothing: whether any given class actually
-- FIRES then depends on live stock, and a class that never fires is a vacuous green (S-132).
-- Roles are assigned once, after the cold-start round, from measured state, and each role's
-- target is chosen so its class is guaranteed by construction:
--   SENSOR    target = capacity + 5           -> count_above_capacity, clamped for estimation
--   RISE      target = believed + 3           -> count_rise_unexplained + confidence decay
--   VENUE     target = believed + 3           -> auto-attributed venue_fill (co_managed+venue)
--   EXPIRED   target = 0                      -> negative_delta_unallocatable, LAW 7 witness
--   NEGRAW    raw currStock = -3              -> v_live_shelf_stock's GREATEST(0,.) floor
--   DECREMENT believed-2, or capacity if 0    -> ordinary derived_decrement sawtooth
--
-- ⛔ WHY RISE/VENUE NEED A driver_confirm FIRST. The estimator only calls a rise unexplained
-- when v_expl < v_delta, where v_expl sums load/venue_fill/spot_buy_receive/CORRECTION events
-- with ts > COALESCE(max(last_verified_at), stock_as_of - 7 days). Cold-start seeds are written
-- as 'correction', so in a soak that compresses 19 observations into seconds every later rise is
-- "already explained" by the seed and the rise classes die after two rounds. The canonical fix
-- is the one the real world uses: a driver_confirm event sets last_verified_at = now(), which
-- re-anchors the window and drops v_expl to 0. ⚠️ This is a genuine property of the estimator
-- worth knowing (see the leg-121 PARKING-LOT entry) - it is masked in production only because
-- real snapshots are 4 h apart and cold starts are rare.
--
-- ── EXPIRY IRON RULE (LAW 7) IS ASSERTED, NOT ASSUMED ──────────────────────────────────────
-- Two independent mechanisms protect it and both are exercised: the estimator's drop allocator
-- selects only buckets with (expiry_bucket IS NULL OR expiry_bucket >= CURRENT_DATE), and
-- record_inventory_event_v3 RAISES on a derived_decrement carrying a past expiry_date. A16
-- asserts zero expired derived_decrements fleet-wide; A17 proves that is non-vacuous by
-- requiring shelves that BOTH held a positive expired bucket AND took a decrement in the same
-- soak; A18 pins the three deliberately planted CURRENT_DATE-30 buckets at exactly their
-- planted quantity across every round.
--
-- ── S-223: ONE TRANSACTION IS NOT ONE SNAPSHOT ─────────────────────────────────────────────
-- READ COMMITTED gives every statement a fresh snapshot and a function cannot raise its own
-- isolation level. cron 44 (prd110_p14_composition_estimator_hourly, "40 * * * *") writes
-- shelf_composition for machine 9acce2bf every hour and takes no lock, so it can commit inside
-- this probe's window. Two guards: the run refuses to start in the :38-:45 minute window unless
-- p_allow_cron_window, and the residue check distinguishes a LEAK (probe rows survived) from a
-- CONCURRENT COMMIT (counts moved but zero probe rows survived) and names which one happened.
--
-- ── SAFETY ────────────────────────────────────────────────────────────────────────────────
--   a. The plant lives in a subtransaction that ALWAYS ends in RAISE - rolled back on the
--      success path and on every error path alike. There is no path that commits it.
--   b. plpgsql VARIABLES survive a subtransaction rollback; rows do not. The metric is read out
--      of variables after the rows are gone.
--   c. Every write goes through a canonical writer: estimate_shelf_composition_v3,
--      record_inventory_event_v3, set_product_sourcing_v3. The only direct-table write is the
--      weimi_device_status snapshot append, which carries no trigger of any kind (verified from
--      pg_trigger: zero non-internal triggers) and which is NOT an Appendix A protected entity.
--   d. ⛔ THE CANONICAL WEIMI WRITER IS DELIBERATELY NOT USED, AND HERE IS WHY, so that this
--      bypass never becomes precedent by silence. `upsert_device_status(items jsonb)` is the
--      canonical ingest writer (it is what n8n calls). Read live from pg_proc, it cannot drive
--      this soak on two independent counts:
--        (i)  it hardcodes `snap_date := CURRENT_DATE` and upserts ON CONFLICT
--             (weimi_device_id, snapshot_date), so it can express exactly ONE snapshot per
--             device per calendar day and cannot step a round forward at all; and
--        (ii) its regression guard `WHERE EXCLUDED.total_curr_stock >=
--             weimi_device_status.total_curr_stock * 0.1` would reject every drop-to-zero round,
--             which is precisely the EXPIRED and NEGRAW storm content.
--      Extending it to take a snapshot timestamp would be a change to a live n8n ingest path in
--      service of a test - out of scope, and worse than the direct append. The append reproduces
--      the writer's own INSERT shape column for column.
--   e. Append-only is respected rather than bypassed: the probe only ever INSERTs into
--      inventory_events, and the undo is a TRANSACTION rollback, not a DELETE - so
--      tg_inventory_events_append_only (BEFORE DELETE OR UPDATE) is never fired and never
--      circumvented. The same holds for tg_product_sourcing_append_only.
--   f. A22 RAISES if a single probe row survives; A23/A24 pin the tables the estimator must
--      never touch, and A24 is CONTENT-sensitive (row counts alone cannot see an UPDATE, which
--      is the only shape an Article 6 violation on warehouse_inventory.status could take).
--      A silent half-rollback cannot read as a pass.
--
-- ── DRY-PROVEN BEFORE THIS FILE WAS WRITTEN (leg 121, R=2) ────────────────────────────────
--   round 0 cold start 527 shelves / 1425 events · storm rounds 544 examined, 0 skipped
--   count_above_capacity 36/round · count_rise_unexplained 26/round · venue_fill 4/round
--   negative_delta_unallocatable 3/round · derived_decrement 475 then 437
--   neg_est 0 · conf_oob 0 · dd_on_expired 0 · cold_start_not_conserved 0
--
-- NOT touched: pod_inventory, warehouse_inventory, refill_plan_output, pod_refill_plan,
-- pod_refills, machines_to_visit, any RPC body, any flag, any cron. No fixture and no assertion
-- is added or changed - S1-S6 stay OUT of golden.fixtures on purpose.

CREATE OR REPLACE FUNCTION golden.stress_s2_v1(
  p_rounds            integer DEFAULT 18,
  p_record            boolean DEFAULT true,
  p_note              text    DEFAULT NULL,
  p_allow_cron_window boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = golden, public, pg_temp
AS $fn$
DECLARE
  v_started   timestamptz := clock_timestamp();
  v_t0        timestamptz := now();          -- transaction timestamp: every probe row carries it
  v_r         int;
  v_snap      timestamptz;
  v_base      timestamptz;
  v_res       jsonb;
  v_rounds_j  jsonb := '[]'::jsonb;
  v_roles     jsonb;
  v_deltas    bigint := 0;
  v_n_dc      int;
  v_n_dev     int;
  v_n_venue   int;
  v_n_exp     int;
  v_conf_b    numeric;
  v_conf_a    numeric;
  v_conf_bad  int := 0;
  v_metric    jsonb;

  v_before    jsonb;
  v_after     jsonb;
  v_residue   bigint;

  v_pass      int := 0;
  v_fail      int := 0;
  v_fails     text[] := ARRAY[]::text[];
  v_ok        boolean;
  v_run       uuid;

  EXP_QTY    constant numeric := 5;
  EXP_OFFSET constant int     := 30;          -- planted expired bucket = CURRENT_DATE - 30
  MARK       constant text    := 'S2probe:leg121';
BEGIN
  IF p_rounds IS NULL OR p_rounds < 1 THEN
    RAISE EXCEPTION 'golden.stress_s2_v1: p_rounds must be >= 1 (got %)', p_rounds;
  END IF;

  -- S-223 guard: cron 44 rewrites shelf_composition at :40 for machine 9acce2bf and takes no lock.
  IF NOT p_allow_cron_window
     AND EXTRACT(minute FROM clock_timestamp())::int BETWEEN 38 AND 45 THEN
    RAISE EXCEPTION 'golden.stress_s2_v1: refusing to start at minute % - cron 44 '
                    '(prd110_p14_composition_estimator_hourly, "40 * * * *") writes '
                    'shelf_composition inside this window and takes no lock. Wait, or pass '
                    'p_allow_cron_window => true and read A23 carefully.',
                    EXTRACT(minute FROM clock_timestamp())::int;
  END IF;

  -- ── BANK: probe-written tables + the five protected tables that must not move ────────────
  SELECT jsonb_build_object(
    'inventory_events',     (SELECT count(*) FROM public.inventory_events),
    'shelf_composition',    (SELECT count(*) FROM public.shelf_composition),
    'inventory_anomalies',  (SELECT count(*) FROM public.inventory_anomalies),
    'weimi_device_status',  (SELECT count(*) FROM public.weimi_device_status),
    'product_sourcing',     (SELECT count(*) FROM public.product_sourcing),
    -- CONTENT fingerprints, not bare counts: an UPDATE moves no count, and an UPDATE is the
    -- only shape an Article 6 violation on warehouse_inventory.status could take.
    'pod_inventory',        (SELECT jsonb_object_agg(s, jsonb_build_array(n, st)) FROM (
                               SELECT COALESCE(status,'-') s, count(*) n,
                                      COALESCE(sum(current_stock),0) st
                                 FROM public.pod_inventory GROUP BY 1) z),
    'warehouse_inventory',  (SELECT jsonb_object_agg(k, jsonb_build_array(n, ws, cs)) FROM (
                               SELECT COALESCE(status,'-')||'/'||COALESCE(provenance_reason,'-') k,
                                      count(*) n, COALESCE(sum(warehouse_stock),0) ws,
                                      COALESCE(sum(consumer_stock),0) cs
                                 FROM public.warehouse_inventory GROUP BY 1) z),
    'refill_plan_output',   (SELECT count(*) FROM public.refill_plan_output),
    'pod_refill_plan',      (SELECT count(*) FROM public.pod_refill_plan),
    'pod_refills',          (SELECT count(*) FROM public.pod_refills)
  ) INTO v_before;

  -- ══════════════════════ PLANT + MEASURE, always rolled back ═════════════════════════════
  BEGIN
    SELECT max(snapshot_at) INTO v_base FROM public.weimi_device_status;
    v_base := GREATEST(v_base, now());

    -- ROUND 0 - cold start against the EXISTING live snapshot. No plant: the real latest
    -- snapshot has never been derived, so this is a genuine observation, not a synthetic one.
    v_res    := public.estimate_shelf_composition_v3(NULL, false, false);
    v_deltas := v_deltas + (v_res->>'shelves_examined')::bigint
                         - (v_res->>'already_processed_skipped')::bigint;
    v_rounds_j := v_rounds_j || jsonb_build_array(jsonb_build_object(
      'r', 0, 'res', v_res,
      'neg_est',  (SELECT count(*) FROM public.shelf_composition WHERE est_qty < 0),
      'conf_oob', (SELECT count(*) FROM public.shelf_composition
                    WHERE confidence < 0 OR confidence > 1)));

    -- ── ROLES, from measured post-cold-start state ─────────────────────────────────────────
    WITH bel AS (
      SELECT sc.shelf_id, COALESCE(sum(c.est_qty),0) AS believed
        FROM public.shelf_configurations sc
        LEFT JOIN public.shelf_composition c ON c.shelf_id = sc.shelf_id
       GROUP BY 1
    ), s AS (
      SELECT ss.shelf_id, ss.machine_id, ss.slot_name, ss.pod_product_id,
             ss.max_stock::int AS cap, b.believed, m.operating_model,
             row_number() OVER (ORDER BY ss.shelf_id) AS rn
        FROM public.v_shelf_state ss
        JOIN public.machines m ON m.machine_id = ss.machine_id
        JOIN bel b ON b.shelf_id = ss.shelf_id
       WHERE ss.pod_product_id IS NOT NULL AND ss.slot_name IS NOT NULL
    ), venue AS (
      SELECT shelf_id, row_number() OVER (ORDER BY (cap-believed) DESC, shelf_id) k
        FROM s WHERE operating_model = 'co_managed' AND cap IS NOT NULL AND cap-believed >= 3
    ), expired AS (
      SELECT shelf_id, row_number() OVER (ORDER BY believed DESC, shelf_id) k
        FROM s WHERE believed >= 4
    ), rise AS (
      SELECT shelf_id, row_number() OVER (ORDER BY (cap-believed) DESC, shelf_id) k
        FROM s WHERE operating_model <> 'co_managed' AND cap IS NOT NULL AND cap-believed >= 3
    ), sensor AS (
      SELECT shelf_id, row_number() OVER (ORDER BY shelf_id) k
        FROM s WHERE cap IS NOT NULL AND cap > 0
    ), assigned AS (
      SELECT s.*, CASE WHEN v.k <= 4  THEN 'VENUE'
                       WHEN e.k <= 3  THEN 'EXPIRED'
                       WHEN r.k <= 20 THEN 'RISE'
                       WHEN n.k <= 40 THEN 'SENSOR'
                       WHEN (s.rn % 47) = 0 THEN 'NEGRAW'
                       ELSE 'DECREMENT' END AS role
        FROM s LEFT JOIN venue   v ON v.shelf_id = s.shelf_id
               LEFT JOIN expired e ON e.shelf_id = s.shelf_id
               LEFT JOIN rise    r ON r.shelf_id = s.shelf_id
               LEFT JOIN sensor  n ON n.shelf_id = s.shelf_id
    )
    SELECT jsonb_object_agg(shelf_id::text, jsonb_build_object(
             'role', role, 'm', machine_id, 'sl', slot_name, 'cap', cap, 'pp', pod_product_id))
      INTO v_roles FROM assigned;

    IF v_roles IS NULL THEN
      RAISE EXCEPTION 'golden.stress_s2_v1: no shelves in v_shelf_state - refusing a vacuous soak';
    END IF;

    -- ── PLANT 1: a venue-sourced edge on the VENUE shelves (canonical writer). Measured live:
    --    ZERO shelves resolve to co_managed+venue today, so without this plant the venue_fill
    --    branch of _estimator_rise_disposition_v3 is unreachable and A09 would be vacuous.
    SELECT count(*) INTO v_n_venue FROM (
      SELECT public.set_product_sourcing_v3(
               (e.value->>'m')::uuid, (e.value->>'pp')::uuid, 'venue',
               'PRD-110 S2 stress probe: co-managed venue-sourced edge, rolled back', NULL)
        FROM jsonb_each(v_roles) e WHERE e.value->>'role' = 'VENUE') z;

    -- ── PLANT 2: a known-expired bucket on the EXPIRED shelves (canonical writer) ──────────
    SELECT count(*) INTO v_n_exp FROM (
      SELECT public.record_inventory_event_v3(
               c.shelf_id, c.boonz_product_id, EXP_QTY, 'correction',
               CURRENT_DATE - EXP_OFFSET, MARK || ':expired-plant',
               'PRD-110 S2: known-expired bucket, EXPIRY IRON RULE witness')
        FROM (SELECT DISTINCT ON (sc.shelf_id) sc.shelf_id, sc.boonz_product_id
                FROM public.shelf_composition sc
                JOIN jsonb_each(v_roles) e ON e.key = sc.shelf_id::text
               WHERE e.value->>'role' = 'EXPIRED'
               ORDER BY sc.shelf_id, sc.est_qty DESC) c) z;

    -- ══════════════════════════════ STORM ROUNDS ═════════════════════════════════════════
    FOR v_r IN 1..p_rounds LOOP
      -- unique_device_status is (weimi_device_id, snapshot_date): step a WHOLE DAY, forward.
      v_snap := date_trunc('day', v_base) + (v_r * interval '1 day') + interval '12 hours';

      -- (a) re-anchor RISE/VENUE belief with a driver_confirm, so the rise that follows is
      --     genuinely unexplained rather than absorbed by the cold-start corrections.
      SELECT count(*) INTO v_n_dc FROM (
        SELECT public.record_inventory_event_v3(
                 c.shelf_id, c.boonz_product_id, 1, 'driver_confirm', c.expiry_bucket,
                 MARK || ':anchor:r' || v_r,
                 'PRD-110 S2: re-anchor belief immediately before a synthetic rise')
          FROM (SELECT DISTINCT ON (sc.shelf_id) sc.shelf_id, sc.boonz_product_id, sc.expiry_bucket
                  FROM public.shelf_composition sc
                  JOIN jsonb_each(v_roles) e ON e.key = sc.shelf_id::text
                 WHERE e.value->>'role' IN ('RISE','VENUE')
                   AND (e.value->>'cap')::int >=
                       (SELECT COALESCE(sum(x.est_qty),0) FROM public.shelf_composition x
                         WHERE x.shelf_id = sc.shelf_id) + 3
                 ORDER BY sc.shelf_id, sc.est_qty DESC) c) z;

      -- confidence on the RISE cohort, measured immediately BEFORE the estimator call
      SELECT COALESCE(avg(c.confidence),1) INTO v_conf_b
        FROM public.shelf_composition c
        JOIN jsonb_each(v_roles) e ON e.key = c.shelf_id::text
       WHERE e.value->>'role' = 'RISE';

      -- (b) append the synthetic WEIMI snapshot
      WITH bel AS (
        SELECT sc.shelf_id,
               COALESCE(sum(c.est_qty),0) AS believed,
               COALESCE(sum(c.est_qty) FILTER (
                 WHERE c.expiry_bucket IS NULL OR c.expiry_bucket >= CURRENT_DATE),0) AS sellable
          FROM public.shelf_configurations sc
          LEFT JOIN public.shelf_composition c ON c.shelf_id = sc.shelf_id
         GROUP BY 1
      ), tgt AS (
        SELECT (e.value->>'m')::uuid AS machine_id, e.value->>'sl' AS slot_name,
               CASE e.value->>'role'
                 WHEN 'NEGRAW'  THEN -3
                 WHEN 'SENSOR'  THEN (e.value->>'cap')::int + 5
                 WHEN 'EXPIRED' THEN 0
                 WHEN 'VENUE'   THEN CASE WHEN (e.value->>'cap')::int >= b.believed + 3
                                          THEN (b.believed + 3)::int ELSE 0 END
                 WHEN 'RISE'    THEN CASE WHEN (e.value->>'cap')::int >= b.believed + 3
                                          THEN (b.believed + 3)::int ELSE 0 END
                 ELSE CASE WHEN b.believed = 0  THEN COALESCE((e.value->>'cap')::int, 6)
                           WHEN b.sellable >= 2 THEN (b.believed - 2)::int
                           ELSE b.believed::int END
               END AS target
          FROM jsonb_each(v_roles) e
          JOIN bel b ON b.shelf_id = e.key::uuid
      ), named AS (          -- what v_live_shelf_stock actually elects: latest per device_name
        SELECT DISTINCT ON (w.device_name) w.*
          FROM public.weimi_device_status w
         ORDER BY w.device_name, w.snapshot_at DESC
      ), latest AS (         -- collapsed to one row per device id (rename aliases share ids)
        SELECT DISTINCT ON (n.weimi_device_id) n.*
          FROM named n ORDER BY n.weimi_device_id, n.snapshot_at DESC
      )
      INSERT INTO public.weimi_device_status
        (machine_id, weimi_device_id, device_code, device_name, is_covered, is_running,
         total_curr_stock, cabinet_count, door_statuses, snapshot_at, snapshot_date)
      SELECT l.machine_id, l.weimi_device_id, l.device_code, l.device_name,
             l.is_covered, l.is_running, l.total_curr_stock, l.cabinet_count,
             (SELECT jsonb_agg(
                cab.val || jsonb_build_object('layers', (
                  SELECT jsonb_agg(
                    lay.val || jsonb_build_object('aisles', (
                      SELECT jsonb_agg(CASE WHEN t.target IS NULL THEN ais.val
                                            ELSE ais.val || jsonb_build_object('currStock', t.target) END)
                        FROM jsonb_array_elements(lay.val->'aisles') ais(val)
                        LEFT JOIN tgt t ON t.machine_id = l.machine_id
                                       AND t.slot_name  = ais.val->>'showName')))
                    FROM jsonb_array_elements(cab.val->'layers') lay(val))))
                FROM jsonb_array_elements(l.door_statuses) cab(val)),
             v_snap, v_snap::date
        FROM latest l
       WHERE l.door_statuses IS NOT NULL;
      GET DIAGNOSTICS v_n_dev = ROW_COUNT;

      -- (c) derive
      v_res    := public.estimate_shelf_composition_v3(NULL, false, false);
      v_deltas := v_deltas + (v_res->>'shelves_examined')::bigint
                           - (v_res->>'already_processed_skipped')::bigint;

      SELECT COALESCE(avg(c.confidence),1) INTO v_conf_a
        FROM public.shelf_composition c
        JOIN jsonb_each(v_roles) e ON e.key = c.shelf_id::text
       WHERE e.value->>'role' = 'RISE';
      IF v_conf_a > v_conf_b THEN v_conf_bad := v_conf_bad + 1; END IF;

      v_rounds_j := v_rounds_j || jsonb_build_array(jsonb_build_object(
        'r', v_r, 'anchors', v_n_dc, 'devices', v_n_dev,
        'conf_before', round(v_conf_b,4), 'conf_after', round(v_conf_a,4),
        'neg_est',  (SELECT count(*) FROM public.shelf_composition WHERE est_qty < 0),
        'conf_oob', (SELECT count(*) FROM public.shelf_composition
                      WHERE confidence < 0 OR confidence > 1),
        'res', v_res));
    END LOOP;

    -- ── FINAL MEASUREMENT, still inside the doomed subtransaction ─────────────────────────
    SELECT jsonb_build_object(
      'deltas_processed', v_deltas,
      'rounds_run',       jsonb_array_length(v_rounds_j),
      'venue_edges',      v_n_venue,
      'expired_plants',   v_n_exp,
      'conf_regressions', v_conf_bad,
      'neg_est_final',    (SELECT count(*) FROM public.shelf_composition WHERE est_qty < 0),
      'conf_oob_final',   (SELECT count(*) FROM public.shelf_composition
                            WHERE confidence < 0 OR confidence > 1),
      'ev_by_kind',       (SELECT jsonb_object_agg(kind, n) FROM (
                             SELECT kind, count(*) n FROM public.inventory_events
                              WHERE ts >= v_t0 GROUP BY 1) z),
      'anom_by_kind',     (SELECT jsonb_object_agg(kind, n) FROM (
                             SELECT kind, count(*) n FROM public.inventory_anomalies
                              WHERE detected_at >= v_t0 GROUP BY 1) z),
      -- LAW 7, the global form: no derived_decrement may carry a past expiry_date.
      'dd_on_expired',    (SELECT count(*) FROM public.inventory_events
                            WHERE ts >= v_t0 AND kind = 'derived_decrement'
                              AND expiry_date IS NOT NULL AND expiry_date < CURRENT_DATE),
      -- LAW 7 non-vacuity: shelves that BOTH carried a positive expired bucket AND took a
      -- decrement in this soak. If this is 0 the assertion above proves nothing.
      'law7_witnesses',   (SELECT count(*) FROM (
                             SELECT c.shelf_id FROM public.shelf_composition c
                              WHERE c.expiry_bucket IS NOT NULL AND c.expiry_bucket < CURRENT_DATE
                                AND c.est_qty > 0
                              INTERSECT
                             SELECT e.shelf_id FROM public.inventory_events e
                              WHERE e.ts >= v_t0 AND e.kind = 'derived_decrement') w),
      -- scoped to the EXPIRED role: a cold-start bucket elsewhere can legitimately land on the
      -- same date (it derives from max(pod_inventory.expiration_date)), and counting those
      -- would red this assertion for a reason that has nothing to do with the plant.
      'planted_expired',  (SELECT jsonb_build_object(
                             'rows',  count(*),
                             'exact', count(*) FILTER (WHERE c.est_qty = EXP_QTY))
                             FROM public.shelf_composition c
                             JOIN jsonb_each(v_roles) e ON e.key = c.shelf_id::text
                            WHERE c.expiry_bucket = CURRENT_DATE - EXP_OFFSET
                              AND e.value->>'role' = 'EXPIRED'),
      -- NEGRAW proves the GREATEST(0,.) floor end-to-end: the SELLABLE belief must be emptied.
      -- Expired buckets are excluded on purpose - LAW 7 forbids draining them, so including
      -- them here would assert the opposite of A16.
      'negraw_sellable',  (SELECT COALESCE(sum(c.est_qty),0) FROM public.shelf_composition c
                             JOIN jsonb_each(v_roles) e ON e.key = c.shelf_id::text
                            WHERE e.value->>'role' = 'NEGRAW'
                              AND (c.expiry_bucket IS NULL OR c.expiry_bucket >= CURRENT_DATE)),
      'negraw_negative',  (SELECT count(*) FROM public.shelf_composition c
                             JOIN jsonb_each(v_roles) e ON e.key = c.shelf_id::text
                            WHERE e.value->>'role' = 'NEGRAW' AND c.est_qty < 0),
      'venue_fill_off_role', (SELECT count(*) FROM public.inventory_events ev
                                LEFT JOIN jsonb_each(v_roles) e ON e.key = ev.shelf_id::text
                               WHERE ev.ts >= v_t0 AND ev.kind = 'venue_fill'
                                 AND COALESCE(e.value->>'role','-') <> 'VENUE'),
      'venue_role_rise_anoms', (SELECT count(*) FROM public.inventory_anomalies a
                                  JOIN jsonb_each(v_roles) e ON e.key = a.shelf_id::text
                                 WHERE a.detected_at >= v_t0
                                   AND a.kind = 'count_rise_unexplained'
                                   AND e.value->>'role' = 'VENUE'),
      'role_counts',      (SELECT jsonb_object_agg(r, n) FROM (
                             SELECT e.value->>'role' r, count(*) n
                               FROM jsonb_each(v_roles) e GROUP BY 1) z),
      'rounds',           v_rounds_j
    ) INTO v_metric;

    RAISE EXCEPTION 'S2_ROLLBACK_PROBE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'S2_ROLLBACK_PROBE' THEN
      RAISE;                                   -- a real error is never swallowed
    END IF;
  END;
  -- rows are gone here; v_metric survived because it is a variable, not a row.

  SELECT jsonb_build_object(
    'inventory_events',     (SELECT count(*) FROM public.inventory_events),
    'shelf_composition',    (SELECT count(*) FROM public.shelf_composition),
    'inventory_anomalies',  (SELECT count(*) FROM public.inventory_anomalies),
    'weimi_device_status',  (SELECT count(*) FROM public.weimi_device_status),
    'product_sourcing',     (SELECT count(*) FROM public.product_sourcing),
    -- CONTENT fingerprints, not bare counts: an UPDATE moves no count, and an UPDATE is the
    -- only shape an Article 6 violation on warehouse_inventory.status could take.
    'pod_inventory',        (SELECT jsonb_object_agg(s, jsonb_build_array(n, st)) FROM (
                               SELECT COALESCE(status,'-') s, count(*) n,
                                      COALESCE(sum(current_stock),0) st
                                 FROM public.pod_inventory GROUP BY 1) z),
    'warehouse_inventory',  (SELECT jsonb_object_agg(k, jsonb_build_array(n, ws, cs)) FROM (
                               SELECT COALESCE(status,'-')||'/'||COALESCE(provenance_reason,'-') k,
                                      count(*) n, COALESCE(sum(warehouse_stock),0) ws,
                                      COALESCE(sum(consumer_stock),0) cs
                                 FROM public.warehouse_inventory GROUP BY 1) z),
    'refill_plan_output',   (SELECT count(*) FROM public.refill_plan_output),
    'pod_refill_plan',      (SELECT count(*) FROM public.pod_refill_plan),
    'pod_refills',          (SELECT count(*) FROM public.pod_refills)
  ) INTO v_after;

  -- Residue is MARKER-based, never clock-based: `ts >= v_t0` would also catch a legitimate
  -- concurrent commit and report it as a leak. Every marker below can only have been written
  -- by this probe, so a non-zero count is unambiguously a rollback failure. The counts that a
  -- concurrent writer CAN move are handled separately, and named as such, by A23.
  SELECT (SELECT count(*) FROM public.inventory_events    WHERE source_ref LIKE MARK || '%')
       + (SELECT count(*) FROM public.weimi_device_status WHERE v_base IS NOT NULL
                                                            AND snapshot_at > v_base)
       + (SELECT count(*) FROM public.product_sourcing
           WHERE reason = 'PRD-110 S2 stress probe: co-managed venue-sourced edge, rolled back')
    INTO v_residue;

  IF v_residue <> 0 THEN
    RAISE EXCEPTION 'golden.stress_s2_v1: PROBE LEAKED - % probe rows survived the rollback. '
                    'Investigate before re-running; do not re-run on top of a leak.', v_residue;
  END IF;

  -- ══════════════════════════════ ASSERTIONS (25) ═════════════════════════════════════════
  v_ok := (v_metric->>'rounds_run')::int = p_rounds + 1;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A01 rounds_run <> p_rounds+1'; END IF;

  v_ok := (v_metric->>'deltas_processed')::bigint >= 10000;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A02 fewer than 10000 deltas processed'; END IF;

  v_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_metric->'rounds') r
                       WHERE COALESCE((r.value->>'neg_est')::int, 1) <> 0);
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A03 negative est_qty seen in some round'; END IF;

  v_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_metric->'rounds') r
                       WHERE COALESCE((r.value->>'conf_oob')::int, 1) <> 0);
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A04 confidence left [0,1] in some round'; END IF;

  v_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_metric->'rounds') r
                       WHERE (r.value->>'r')::int > 0
                         AND COALESCE((r.value->'res'->>'sensor_above_capacity')::int, 0) = 0);
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A05 a storm round raised no count>capacity'; END IF;

  v_ok := COALESCE((v_metric->'anom_by_kind'->>'count_above_capacity')::int, 0) >= 30 * p_rounds;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A06 too few count_above_capacity anomalies'; END IF;

  v_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_metric->'rounds') r
                       WHERE (r.value->>'r')::int > 0
                         AND COALESCE((r.value->'res'->>'rises_flagged_anomaly')::int, 0) = 0);
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A07 a storm round flagged no unexplained rise'; END IF;

  v_ok := COALESCE((v_metric->'anom_by_kind'->>'count_rise_unexplained')::int, 0) > 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A08 no count_rise_unexplained anomaly'; END IF;

  v_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_metric->'rounds') r
                       WHERE (r.value->>'r')::int > 0
                         AND COALESCE((r.value->'res'->>'rises_auto_venue_fill')::int, 0) = 0);
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A09 a storm round auto-attributed no venue fill'; END IF;

  v_ok := COALESCE((v_metric->'ev_by_kind'->>'venue_fill')::int, 0) > 0
      AND (v_metric->>'venue_fill_off_role')::int = 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A10 venue_fill missing, or landed off the VENUE role'; END IF;

  v_ok := (v_metric->>'venue_role_rise_anoms')::int = 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A11 a VENUE-role rise was flagged instead of attributed'; END IF;

  v_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_metric->'rounds') r
                       WHERE (r.value->>'r')::int > 0
                         AND COALESCE((r.value->'res'->>'count_drops_allocated')::int, 0) = 0);
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A12 a storm round allocated no ordinary decrement'; END IF;

  v_ok := COALESCE((v_metric->'ev_by_kind'->>'derived_decrement')::int, 0) > 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A13 no derived_decrement event written'; END IF;

  v_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_metric->'rounds') r
                       WHERE (r.value->>'r')::int > 0
                         AND COALESCE((r.value->'res'->>'unallocatable_residuals')::int, 0) = 0);
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A14 a storm round produced no unallocatable residual'; END IF;

  v_ok := COALESCE((v_metric->'anom_by_kind'->>'negative_delta_unallocatable')::int, 0) > 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A15 no negative_delta_unallocatable anomaly'; END IF;

  -- LAW 7
  v_ok := (v_metric->>'dd_on_expired')::int = 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A16 EXPIRY IRON RULE broken: a derived_decrement consumed an expired bucket'; END IF;

  v_ok := (v_metric->>'law7_witnesses')::int > 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A17 A16 is vacuous: no shelf both held expired stock and took a decrement'; END IF;

  v_ok := (v_metric->'planted_expired'->>'rows')::int = (v_metric->>'expired_plants')::int
      AND (v_metric->'planted_expired'->>'exact')::int = (v_metric->>'expired_plants')::int;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A18 a planted expired bucket moved during the soak'; END IF;

  v_ok := (v_metric->>'negraw_sellable')::numeric = 0
      AND (v_metric->>'negraw_negative')::int = 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A19 a raw-negative WEIMI count did not floor to an empty sellable shelf'; END IF;

  v_ok := (v_metric->>'conf_regressions')::int = 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A20 confidence rose across an unexplained-delta round'; END IF;

  v_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_metric->'rounds') r
                       WHERE COALESCE((r.value->'res'->>'cold_start_not_conserved')::int, 1) <> 0);
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A21 a cold-start seed failed to conserve the WEIMI count'; END IF;

  v_ok := v_residue = 0;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A22 probe rows survived the rollback'; END IF;

  -- A23: the five tables the probe writes must be back exactly where they started. A move with
  -- zero residue is a CONCURRENT COMMIT (cron 44), not a leak - the message says which.
  v_ok := (v_before->>'inventory_events')    = (v_after->>'inventory_events')
      AND (v_before->>'shelf_composition')   = (v_after->>'shelf_composition')
      AND (v_before->>'inventory_anomalies') = (v_after->>'inventory_anomalies')
      AND (v_before->>'weimi_device_status') = (v_after->>'weimi_device_status')
      AND (v_before->>'product_sourcing')    = (v_after->>'product_sourcing');
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1;
    v_fails:=v_fails||'A23 a probe-written table moved with zero probe residue - a concurrent writer (cron 44) committed inside the window; re-run outside :38-:45'; END IF;

  v_ok := (v_before->'pod_inventory')       = (v_after->'pod_inventory')
      AND (v_before->'warehouse_inventory')  = (v_after->'warehouse_inventory')
      AND (v_before->>'refill_plan_output')  = (v_after->>'refill_plan_output')
      AND (v_before->>'pod_refill_plan')     = (v_after->>'pod_refill_plan')
      AND (v_before->>'pod_refills')         = (v_after->>'pod_refills');
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A24 a protected table moved - the estimator must touch none of them'; END IF;

  v_ok := EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000 < 600000;
  IF v_ok THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||'A25 soak exceeded the 600 000 ms budget'; END IF;

  v_metric := v_metric || jsonb_build_object(
    'before', v_before, 'after', v_after, 'residue', v_residue,
    'duration_ms', round(EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000),
    'n_pass', v_pass, 'n_fail', v_fail, 'failures', to_jsonb(v_fails));

  IF p_record THEN
    v_run := golden.record_stress(
      p_suite      => 'S2',
      p_passed     => (v_fail = 0),
      p_started_at => v_started,
      p_metric     => v_metric - 'rounds',
      p_detail     => jsonb_build_object('rounds', v_metric->'rounds'),
      p_note       => COALESCE(p_note,
                        'S2 estimator soak. p_rounds+1 fleet derivations over synthetic '
                        'weimi_device_status snapshots, role-driven anomaly storm (count>capacity, '
                        'raw-negative counts, drops beyond sellable belief, venue fills, ordinary '
                        'decrements). Rollback-restored probe: nothing persists in inventory_events, '
                        'shelf_composition, inventory_anomalies, weimi_device_status or '
                        'product_sourcing. Consumes no plan_date, so 2030-11-02 is released.'),
      p_driver     => 'sql',
      p_n_pass     => v_pass,
      p_n_fail     => v_fail);
    v_metric := v_metric || jsonb_build_object('stress_run_id', v_run);
  END IF;

  RETURN v_metric - 'rounds';
END
$fn$;

REVOKE ALL ON FUNCTION golden.stress_s2_v1(integer, boolean, text, boolean) FROM PUBLIC;

COMMENT ON FUNCTION golden.stress_s2_v1(integer, boolean, text, boolean) IS
  'PRD-110 STEP 7 / S2. Estimator soak: one cold-start derivation plus p_rounds (default 18) '
  'storm rounds over synthetic weimi_device_status snapshots, >= 10 000 shelf observations '
  'processed. Roles guarantee every storm class fires: count>capacity, raw-negative counts, '
  'drops beyond sellable belief, co-managed venue fills, ordinary decrements. Asserts 25 '
  'properties - composition never negative, confidence inside [0,1] and never rising across an '
  'unexplained-delta round, the EXPIRY IRON RULE holds with a proven-non-vacuous witness set, '
  'cold-start conservation, and that five protected tables never move. Everything runs inside a '
  'subtransaction that always rolls back; the function RAISES if a single probe row survives. '
  'Refuses to start at minute 38-45 (cron 44 writes shelf_composition unlocked) unless '
  'p_allow_cron_window. Records into golden.stress_runs unless p_record=false.';
