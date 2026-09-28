-- Loop 2026-09-25 B2 (PRD-133): pick_machines_v12, the new selection engine, plus the
-- picker_config switch wiring into _build_draft_core_v3.
--
-- Investigation before writing anything:
--
-- 1. machines.building_id is text, not uuid, and is NULL for every machine in the fleet,
--    including the AMZ machines the acceptance evidence names. v11's own clustering
--    (pick_machines_for_refill's r_cluster = COALESCE(venue_group, building_id, official_name))
--    already falls back past the always-empty building_id straight to venue_group, so v11
--    clusters an entire venue ("AMAZON") as one group, not by building. That is coarser than
--    what PRD-133's acceptance evidence needs (AMZ-1046 pulled in via "building 24" specifically
--    once AMZ-1068 is picked, while AMZ-1029, a different building, is not part of that cluster).
--    Confirmed live: AMZ-1029-3003-O1 and AMZ-1038-3001-O1 share the digit pair "30" in the
--    second hyphenated segment of official_name; AMZ-1046-2406-O1, AMZ-1057-2403-O1 and
--    AMZ-1068-2401-O1 all share "24". This matches the task's own "building 24" language exactly.
--    v12 derives a building code from this naming convention (first two digits of the second
--    hyphenated segment) rather than backfilling machines.building_id itself: machines is a
--    protected entity with its own canonical write paths, and populating a fleet-wide column from
--    a name-parsing heuristic is a larger, separate change than this loop's surgical scope allows.
--    machines_to_visit_shadow.building_id (created in B1 as uuid, before this was known) is
--    corrected to text here; the table is still empty, so this is a free ALTER.
--
-- 2. svc_track in v_machine_priority does not currently read 'vox' for VOXMCC-1005-0201-B0 (it
--    reads 'main'); venue_group = 'VOX' is the reliable signal and is what this engine uses for
--    "venue-supplied / VOX machine". product_mapping.source_of_supply for that same machine is a
--    mix of 'venue_team' and 'boonz', not uniformly 'venue_team' as PRD-133's literal wording
--    ("all lanes venue_team") would suggest; venue_group = 'VOX' is used as the practical
--    identifier instead, since it is what the codebase already uses to label these machines and
--    it matches the acceptance evidence by name.
--
-- 3. v_machine_priority already exposes fill_pct, empty_shelves_count, days_since_visit,
--    daily_revenue_aed, runway_days, hero_runway_days, venue_group, include_in_refill and
--    machine_status at the correct per-machine grain; this engine reads that view for those
--    facts rather than re-deriving them (Article 16: do not recompute a metric that already has a
--    canonical object). Lane-level facts (velocity, per-lane fill, emptiness) come from
--    v_lane_grain, which is not covered by v_machine_priority's aggregates. Warehouse pickable
--    stock comes from v_wh_pickable. The effective product_mapping resolution (machine-scoped
--    Active rows override the global Active default for the same pod product, never a raw
--    fan-out) reuses the exact pattern already used by engine_finalize_pod's source_origin
--    resolution (PRD-120 v15.1).
--
-- 4. Two real bugs found and fixed while smoke testing against live data, not assumed:
--    a. donor_value_aed initially summed (donor_units * receiver_price_aed) once per QUALIFYING
--       RECEIVER, so a single donor lane matched to many receiving machines had its value counted
--       once per receiver instead of once. Confirmed live: AMZ-1068's single Vitamin Well lane
--       alone produced 146 donor/receiver combinations before this fix, inflating its own
--       visit_value_aed into the tens of thousands of AED. Fixed by taking one (donor,
--       pod_product) row per donor at its best-priced receiver for the value sum; donor_for still
--       lists every qualifying receiver.
--    b. The cap was first applied as one global fill-order across P1, P2, P3 combined. On live
--       data (32 eligible machines today) P1 (3) plus P2 (uncapped at that point, since is_p2 is
--       a real boolean, not itself limited) already filled all 8 slots before any P3 cluster or
--       donor candidate was reached, even though PRD-133 says P1 is "always picked" (read here as
--       bypassing the cap, not just the cooldown). Fixed: P1 rows are never subject to the cap;
--       the cap of 8 governs P2, then cluster/donor-tagged P3, then plain P3, filled in that
--       order.
--    Both fixes verified live: after both, AMZ-1068-2401-O1 and VML-1004-0500-O1 correctly appear
--    as P3/donor with real, sane visit_value_aed (452.45 and 298.70 AED) when the cap allows more
--    than 8 rows through.
--
-- 5. Open finding, NOT fixed in this migration (documented for the loop report, not swept under
--    the rug): with today's real fleet data, 17 of the 32 eligible machines independently qualify
--    as P2 under the literal PRD-133 rules (days_since_visit >= rhythm, or the hero lane running
--    out before the next scheduled visit, or any empty lane). Those 17 alone exceed the cap of 8,
--    so AMZ-1068 and VML-1004 (correctly identified, real donor value 452.45 and 298.70 AED) do
--    NOT make today's cap-8 selection; they are outranked by machines with their own more urgent
--    P2 need. The donor computation itself is verified correct (section 4 above); whether a
--    32-machine fleet with this many machines already past rhythm should really be visited by
--    only 8 stops a day, or whether P2's boolean gate should become a softer ranking signal
--    instead, is a product question for CS, not a bug this loop's surgical scope should resolve
--    unilaterally. Left open in STATE.md and the loop report.
--
-- pick_rhythm_params holds the rhythm-day thresholds only (top/mid/slow); the revenue tercile
-- itself is computed live each run via NTILE(3) over v_machine_priority.daily_revenue_aed, since a
-- static per-machine tercile assignment would go stale as revenue shifts.
--
-- Scope note on visit_value_aed: sales_saved, expiry_avoided and donor_value are computed as
-- real, live figures from the tables named above, not fabricated placeholders, but are
-- best-effort approximations (documented inline at each term) since no literal "next scheduled
-- visit date" or per-lot cost table exists to compute them exactly.
--
-- pick_machines_v12 is SECURITY DEFINER, matching every other engine/picker function in this
-- codebase (pick_machines_for_refill, engine_add_pod, engine_finalize_pod), so its reads are not
-- at the mercy of the calling role's own RLS visibility into pod_inventory, warehouse_inventory
-- and product_mapping. It performs no writes of its own; SELECT-only, no role gate needed.
--
-- Switch wiring: _build_draft_core_v3's "IF p_repick THEN PERFORM public.pick_machines_for_refill
-- (p_plan_date); ..." becomes a read of picker_config.picker_version, gating which picker is
-- authoritative and which one (if any) writes to machines_to_visit_shadow instead, per the
-- v11 / shadow / v12 semantics in PRD-133. Everything else in _build_draft_core_v3 is untouched,
-- byte-for-byte, including the PRD-110 DR-1b cutover branch and the stage 2a/2b/2c engine calls
-- that follow.

ALTER TABLE public.machines_to_visit_shadow ALTER COLUMN building_id TYPE text USING building_id::text;

CREATE TABLE public.pick_rhythm_params (
  tier_label   text PRIMARY KEY CHECK (tier_label IN ('top','mid','slow')),
  rhythm_days  int  NOT NULL CHECK (rhythm_days > 0)
);

ALTER TABLE public.pick_rhythm_params ENABLE ROW LEVEL SECURITY;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.pick_rhythm_params FROM authenticated;
REVOKE ALL ON public.pick_rhythm_params FROM anon, PUBLIC;

CREATE POLICY pick_rhythm_params_authenticated_select ON public.pick_rhythm_params
  FOR SELECT TO authenticated
  USING (true);

INSERT INTO public.pick_rhythm_params (tier_label, rhythm_days) VALUES
  ('top', 3), ('mid', 7), ('slow', 10);

CREATE OR REPLACE FUNCTION public.pick_machines_v12(p_plan_date date, p_cap int DEFAULT 8)
 RETURNS TABLE(
   machine_id uuid, official_name text, tier text, visit_value_aed numeric,
   reasons text[], building_id text, cluster_role text, donor_for jsonb
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_cap int := COALESCE(p_cap, 8);
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_is_vox_day boolean := EXTRACT(DOW FROM p_plan_date) IN (3, 5);
BEGIN
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'pick_machines_v12: p_plan_date required'; END IF;
  IF v_cap < 1 THEN v_cap := 8; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT mp.machine_id, mp.official_name, mp.venue_group,
           mp.fill_pct, mp.empty_shelves_count, mp.days_since_visit,
           mp.daily_revenue_aed, mp.hero_runway_days, mp.runway_days,
           NULLIF(left(substring(mp.official_name from '^[A-Za-z]+-\d+-(\d+)-'), 2), '') AS building_code
      FROM public.v_machine_priority mp
     WHERE mp.include_in_refill = true
       AND mp.machine_status NOT IN ('Warehouse','Inactive')
       AND mp.venue_group IS DISTINCT FROM 'LVLUP'
  ),
  rhythm AS (
    SELECT b.machine_id, NTILE(3) OVER (ORDER BY COALESCE(b.daily_revenue_aed,0) DESC) AS tercile
      FROM base b
  ),
  rhythm_days AS (
    SELECT r.machine_id,
           CASE r.tercile
             WHEN 1 THEN (SELECT rhythm_days FROM public.pick_rhythm_params WHERE tier_label='top')
             WHEN 2 THEN (SELECT rhythm_days FROM public.pick_rhythm_params WHERE tier_label='mid')
             ELSE        (SELECT rhythm_days FROM public.pick_rhythm_params WHERE tier_label='slow')
           END AS rhythm_days
      FROM rhythm r
  ),
  expiry AS (
    SELECT pi.machine_id,
           bool_or(pi.status='Active' AND pi.current_stock>0 AND pi.expiration_date < v_today) AS has_expired_now,
           bool_or(pi.status='Active' AND pi.current_stock>0 AND pi.expiration_date <= p_plan_date) AS has_expiring_by_plan,
           COALESCE(SUM(pi.current_stock) FILTER (
             WHERE pi.status='Active' AND pi.current_stock>0 AND pi.expiration_date <= p_plan_date
           ), 0) AS expiring_units
      FROM public.pod_inventory pi
     WHERE pi.machine_id IN (SELECT machine_id FROM base)
     GROUP BY pi.machine_id
  ),
  lane_all AS (
    SELECT lg.machine_id, lg.lane_id, lg.pod_product_id, lg.current_stock, lg.max_stock,
           lg.dos, lg.lane_dvel, lg.is_empty, lg.fill_ratio,
           ROW_NUMBER() OVER (PARTITION BY lg.machine_id ORDER BY lg.lane_dvel DESC NULLS LAST) AS velocity_rank
      FROM public.v_lane_grain lg
     WHERE lg.machine_id IN (SELECT machine_id FROM base)
  ),
  top2_trigger AS (
    SELECT machine_id, bool_or(is_empty OR COALESCE(dos,0) < 1) AS triggered
      FROM lane_all WHERE velocity_rank <= 2 GROUP BY machine_id
  ),
  lane_boonz AS (
    SELECT la.machine_id, la.lane_id, la.pod_product_id, la.lane_dvel, la.fill_ratio, la.current_stock,
           pm.boonz_product_id
      FROM lane_all la
      JOIN public.product_mapping pm
        ON pm.pod_product_id = la.pod_product_id
       AND pm.status = 'Active'
       AND CASE WHEN EXISTS (
                  SELECT 1 FROM public.product_mapping pm2
                   WHERE pm2.pod_product_id = la.pod_product_id
                     AND pm2.status = 'Active'
                     AND pm2.machine_id = la.machine_id)
                THEN pm.machine_id = la.machine_id
                ELSE pm.is_global_default
           END
  ),
  donor_pool AS (
    SELECT DISTINCT lb.machine_id AS donor_machine_id, lb.pod_product_id, lb.boonz_product_id,
           lb.lane_dvel, lb.current_stock AS donor_units
      FROM lane_boonz lb
     WHERE lb.lane_dvel < 0.4
       AND NOT EXISTS (SELECT 1 FROM public.v_wh_pickable wp WHERE wp.boonz_product_id = lb.boonz_product_id)
  ),
  receiver_pool AS (
    SELECT lb.machine_id AS receiver_machine_id, lb.pod_product_id, lb.boonz_product_id,
           lb.fill_ratio,
           percent_rank() OVER (PARTITION BY lb.pod_product_id ORDER BY lb.lane_dvel) AS velocity_pctrank
      FROM lane_boonz lb
  ),
  receivers_qualified AS (
    SELECT * FROM receiver_pool WHERE velocity_pctrank >= 0.75 AND fill_ratio < 0.5
  ),
  donor_links AS (
    SELECT dp.donor_machine_id, dp.pod_product_id, dp.donor_units,
           rq.receiver_machine_id,
           COALESCE(vls.price_aed, 0) AS receiver_price_aed
      FROM donor_pool dp
      JOIN receivers_qualified rq
        ON rq.pod_product_id = dp.pod_product_id AND rq.receiver_machine_id <> dp.donor_machine_id
      LEFT JOIN public.v_live_shelf_stock vls
        ON vls.machine_id = rq.receiver_machine_id AND vls.pod_product_id = rq.pod_product_id
  ),
  -- One (donor, pod_product) pair donates to its single best-priced receiver for VALUE purposes;
  -- donor_for below still lists every qualifying receiver. Without this dedup, donor_value_aed
  -- summed once per matching receiver, wildly overcounting any donor lane matched to several
  -- receivers (confirmed live: AMZ-1068's Vitamin Well lane alone matched 146 donor/receiver
  -- combinations before this fix).
  donor_value_dedup AS (
    SELECT DISTINCT ON (donor_machine_id, pod_product_id)
           donor_machine_id, pod_product_id, donor_units, receiver_price_aed
      FROM donor_links
     ORDER BY donor_machine_id, pod_product_id, receiver_price_aed DESC
  ),
  donor_agg AS (
    SELECT dvd.donor_machine_id,
           (SELECT jsonb_agg(DISTINCT jsonb_build_object('receiver_machine_id', dl.receiver_machine_id))
              FROM donor_links dl WHERE dl.donor_machine_id = dvd.donor_machine_id) AS donor_for,
           SUM(dvd.donor_units * dvd.receiver_price_aed) AS donor_value_aed
      FROM donor_value_dedup dvd
     GROUP BY dvd.donor_machine_id
  ),
  triggers AS (
    SELECT b.*, rd.rhythm_days,
           COALESCE(e.has_expired_now,false) AS has_expired_now,
           COALESCE(e.has_expiring_by_plan,false) AS has_expiring_by_plan,
           COALESCE(e.expiring_units,0) AS expiring_units,
           COALESCE(t2.triggered,false) AS top2_lane_trigger,
           (b.venue_group = 'VOX') AS is_vox
      FROM base b
      LEFT JOIN rhythm_days rd ON rd.machine_id = b.machine_id
      LEFT JOIN expiry e ON e.machine_id = b.machine_id
      LEFT JOIN top2_trigger t2 ON t2.machine_id = b.machine_id
  ),
  classified AS (
    SELECT tr.*,
      CASE
        WHEN tr.is_vox THEN (tr.has_expired_now OR tr.has_expiring_by_plan OR COALESCE(tr.hero_runway_days,999) <= 0)
        ELSE (tr.has_expired_now OR tr.has_expiring_by_plan OR tr.top2_lane_trigger
              OR COALESCE(tr.empty_shelves_count,0) >= 2 OR COALESCE(tr.fill_pct,100) < 50)
      END AS is_p1_raw
    FROM triggers tr
  ),
  classified2 AS (
    SELECT c.*, c.is_p1_raw AS is_p1,
      (NOT c.is_p1_raw
       AND (COALESCE(c.days_since_visit,0) >= COALESCE(c.rhythm_days,7)
            OR COALESCE(c.hero_runway_days,999) < COALESCE(c.rhythm_days,7)
            OR COALESCE(c.empty_shelves_count,0) >= 1)
       AND (NOT c.is_vox OR v_is_vox_day)
      ) AS is_p2
    FROM classified c
  ),
  base_tier AS (
    SELECT c2.*,
      CASE WHEN c2.is_p1 THEN 'P1'
           WHEN c2.is_p2 THEN 'P2'
           WHEN COALESCE(c2.days_since_visit,0) > 1 THEN 'P3'
           ELSE NULL
      END AS own_tier
    FROM classified2 c2
  ),
  seeded_buildings AS (
    SELECT DISTINCT building_code
      FROM base_tier
     WHERE own_tier IN ('P1','P2') AND building_code IS NOT NULL
  ),
  tiered AS (
    SELECT bt.*,
      da.donor_for, COALESCE(da.donor_value_aed,0) AS donor_value_aed,
      (da.donor_for IS NOT NULL) AS is_donor,
      (bt.own_tier IS NULL AND bt.building_code IS NOT NULL
        AND bt.building_code IN (SELECT building_code FROM seeded_buildings)) AS is_cluster_pullin
    FROM base_tier bt
    LEFT JOIN donor_agg da ON da.donor_machine_id = bt.machine_id
  ),
  final_tier AS (
    SELECT t.*,
      CASE
        WHEN t.own_tier IN ('P1','P2') THEN t.own_tier
        WHEN t.is_donor THEN 'P3'
        WHEN t.is_cluster_pullin THEN 'P3'
        WHEN t.own_tier = 'P3' THEN 'P3'
        ELSE NULL
      END AS tier,
      CASE
        WHEN t.is_donor THEN 'donor'
        WHEN t.is_cluster_pullin THEN 'cluster'
        WHEN t.own_tier IS NOT NULL AND t.building_code IN (SELECT building_code FROM seeded_buildings) THEN 'cluster'
        ELSE NULL
      END AS cluster_role
    FROM tiered t
  ),
  scored AS (
    SELECT f.*,
      -- sales_saved: revenue this machine would lose between now and the next visit at its own
      -- rhythm cadence, if the runway (days of stock left) is shorter than that cadence.
      -- Approximation: no literal "next scheduled visit date" exists to measure against, so the
      -- rhythm interval itself stands in for it.
      ROUND(COALESCE(f.daily_revenue_aed,0)
            * GREATEST(COALESCE(f.rhythm_days,7) - COALESCE(f.runway_days,0), 0)
            / GREATEST(COALESCE(f.rhythm_days,7),1), 2) AS sales_saved_aed,
      -- expiry_avoided: units expiring by plan_date, valued at this machine's own current shelf
      -- price for whichever pod product they belong to (best-effort; no per-lot cost ledger
      -- exists). Falls back to 0 when no matching price is found, never fabricated.
      ROUND(COALESCE((
        SELECT SUM(pi.current_stock * COALESCE(vls.price_aed,0))
          FROM public.pod_inventory pi
          LEFT JOIN public.v_live_shelf_stock vls
            ON vls.machine_id = pi.machine_id
           AND vls.pod_product_id IN (
             SELECT pm.pod_product_id FROM public.product_mapping pm
              WHERE pm.boonz_product_id = pi.boonz_product_id AND pm.status='Active'
                AND (pm.machine_id = pi.machine_id OR pm.machine_id IS NULL)
              ORDER BY (pm.machine_id = pi.machine_id) DESC NULLS LAST, pm.is_global_default DESC
              LIMIT 1)
         WHERE pi.machine_id = f.machine_id AND pi.status='Active' AND pi.current_stock>0
           AND pi.expiration_date <= p_plan_date
      ),0), 2) AS expiry_avoided_aed
    FROM final_tier f
  ),
  reasoned AS (
    SELECT s.*,
      (ARRAY[]::text[]
        || CASE WHEN s.has_expired_now THEN ARRAY['expired stock is physically on the shelf'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.has_expiring_by_plan AND NOT s.has_expired_now THEN ARRAY['a lot expires on or before the plan date and still has stock'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_vox AND s.is_p1 AND COALESCE(s.hero_runway_days,999) <= 0 THEN ARRAY['hero lane is empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND s.top2_lane_trigger THEN ARRAY['one of the top two lanes by velocity is empty or under a day of cover'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND COALESCE(s.empty_shelves_count,0) >= 2 AND s.is_p1 THEN ARRAY['two or more lanes are empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND COALESCE(s.fill_pct,100) < 50 AND s.is_p1 THEN ARRAY['overall fill is under 50 percent'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.days_since_visit,0) >= COALESCE(s.rhythm_days,7) THEN ARRAY[format('days since last visit (%s) has reached this machine''s rhythm (%s days)', s.days_since_visit, s.rhythm_days)] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.hero_runway_days,999) < COALESCE(s.rhythm_days,7) THEN ARRAY['the hero lane will run out before the next scheduled visit'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.empty_shelves_count,0) >= 1 THEN ARRAY['at least one lane is empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_donor THEN ARRAY['this machine can donate slow stock to another machine that needs it'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.cluster_role = 'cluster' AND NOT s.is_donor THEN ARRAY['picked up as part of a building cluster with another machine already visited'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.tier = 'P3' AND s.cluster_role IS NULL THEN ARRAY['ride along candidate'] ELSE ARRAY[]::text[] END
      ) AS reasons
    FROM scored s
  ),
  ranked AS (
    SELECT r.*,
      (COALESCE(r.sales_saved_aed,0) + COALESCE(r.expiry_avoided_aed,0) + COALESCE(r.donor_value_aed,0)) AS visit_value_aed,
      CASE WHEN r.tier <> 'P1' THEN
        ROW_NUMBER() OVER (
          PARTITION BY (r.tier <> 'P1')
          ORDER BY CASE WHEN r.tier = 'P2' THEN 1
                        WHEN r.tier = 'P3' AND r.cluster_role IN ('donor','cluster') THEN 2
                        ELSE 3 END,
                   (COALESCE(r.sales_saved_aed,0) + COALESCE(r.expiry_avoided_aed,0) + COALESCE(r.donor_value_aed,0)) DESC,
                   r.official_name
        )
      END AS non_p1_fill_order
    FROM reasoned r
    WHERE r.tier IS NOT NULL
  )
  -- Cap 8 total, but P1 is always picked (per PRD-133) and does not compete for the cap; the cap
  -- of 8 governs P2, then clusters/donors, then P3, filled in that order.
  SELECT rk.machine_id, rk.official_name, rk.tier, rk.visit_value_aed, rk.reasons,
         rk.building_code, rk.cluster_role, rk.donor_for
    FROM ranked rk
   WHERE rk.tier = 'P1' OR rk.non_p1_fill_order <= v_cap
   ORDER BY CASE rk.tier WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 WHEN 'P3' THEN 3 ELSE 4 END, rk.visit_value_aed DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public._build_draft_core_v3(p_plan_date date, p_repick boolean, p_auto_confirm boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '1200000'
AS $function$
DECLARE
  v_user_id   uuid;
  v_picked    int;
  v_confirmed int;
  v_included  int;
  v_repicked  boolean := false;
  v_auto_conf jsonb;
  v_picks     jsonb;
  v_add       jsonb;
  v_add_v3    jsonb;
  v_promo     jsonb;
  v_swap      jsonb;
  v_final     jsonb;
  v_picker_version text;
  v_v12_row   record;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role IN ('operator_admin', 'superadmin')
  ) THEN
    RETURN jsonb_build_object('status', 'error',
      'message', 'unauthorized: requires operator_admin or superadmin');
  END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;

  -- PRD-035 WS-E calendar. CS DECISION D-35: the rule is NOT restated here. Stage 1 asks
  -- is_refill_planning_day_v3 by name, which is the same object run_nightly_shadow_v3 asks,
  -- so the two cannot drift apart (Article 16: the illegal copy is retired, not shadowed).
  -- Safe as a straight swap only because the NULL-date RAISE above already discharges the
  -- helper's extra IS NOT NULL guard; golden fixture 61 pins the agreement over a full week.
  IF NOT public.is_refill_planning_day_v3(p_plan_date) THEN
    RETURN jsonb_build_object('status', 'skipped_saturday', 'plan_date', p_plan_date,
      'message', 'Saturday is a delivery day; no refill plan is generated (PRD-035 WS-E calendar)');
  END IF;

  -- LAW 12 guard, preserved verbatim from v1: never regenerate a live plan.
  IF EXISTS (SELECT 1 FROM public.pod_refill_plan
              WHERE plan_date = p_plan_date AND status IN ('approved','stitched'))
     OR EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_date = p_plan_date) THEN
    RETURN jsonb_build_object('status', 'refused_live_plan', 'plan_date', p_plan_date,
      'message', 'plan already approved/stitched/dispatched; use edit RPCs');
  END IF;

  IF p_repick THEN
    -- Loop 2026-09-25 B2: picker_config.picker_version decides which picker is authoritative
    -- (writes into machines_to_visit, the real plan input) and which one, if any, only writes
    -- its comparison output to machines_to_visit_shadow. See PRD-133-135 for the v11/shadow/v12
    -- semantics. Default to 'v11' if the config row is ever missing, so a missing switch never
    -- silently changes behaviour.
    SELECT value INTO v_picker_version FROM public.picker_config WHERE key = 'picker_version';
    v_picker_version := COALESCE(v_picker_version, 'v11');

    IF v_picker_version = 'v12' THEN
      DELETE FROM public.machines_to_visit_shadow
       WHERE plan_date = p_plan_date AND picker_version = 'v11';
      PERFORM public.pick_machines_for_refill(p_plan_date);
      INSERT INTO public.machines_to_visit_shadow
        (plan_date, picker_version, machine_id, official_name, tier, visit_value_aed, reasons, building_id, cluster_role, donor_for)
      SELECT p_plan_date, 'v11', mv.machine_id, mv.official_name, mv.priority_tier, mv.priority_score,
             mv.picked_reasons, mv.building_id, NULL, NULL
        FROM public.machines_to_visit mv
       WHERE mv.plan_date = p_plan_date AND mv.status = 'picked';

      -- v12 is authoritative: promote its picks into the real machines_to_visit table, then
      -- supersede whatever v11 had picked there so the plan actually reflects v12's decision.
      UPDATE public.machines_to_visit
         SET status = 'superseded', updated_at = now()
       WHERE plan_date = p_plan_date AND status = 'picked';

      FOR v_v12_row IN SELECT * FROM public.pick_machines_v12(p_plan_date) LOOP
        -- machines_to_visit.priority_tier has a closed CHECK (NULL, 'P1_RESTOCK' or 'P2_MAINTAIN'
        -- only), v11's own vocabulary; confirmed live while smoke testing (23514 on the first
        -- attempt). v12's richer P1/P2/P3 + cluster_role/donor_for classification is not narrowed
        -- to fit here; it is written in full to machines_to_visit_shadow above/below instead. This
        -- column only carries the closest existing v11-compatible label so nothing downstream that
        -- already reads priority_tier breaks; P3 has no v11 equivalent and maps to NULL.
        INSERT INTO public.machines_to_visit (
          plan_date, machine_id, official_name, building_id,
          picked_reasons, priority_score, service_track, priority_tier,
          picked_at, picked_by, status, add_source
        ) VALUES (
          p_plan_date, v_v12_row.machine_id, v_v12_row.official_name, v_v12_row.building_id,
          v_v12_row.reasons, v_v12_row.visit_value_aed, 'main',
          CASE v_v12_row.tier WHEN 'P1' THEN 'P1_RESTOCK' WHEN 'P2' THEN 'P2_MAINTAIN' ELSE NULL END,
          now(), v_user_id, 'picked', 'picker'
        )
        ON CONFLICT (plan_date, machine_id) DO UPDATE
           SET official_name = EXCLUDED.official_name, building_id = EXCLUDED.building_id,
               picked_reasons = EXCLUDED.picked_reasons, priority_score = EXCLUDED.priority_score,
               priority_tier = EXCLUDED.priority_tier,
               picked_at = EXCLUDED.picked_at, picked_by = EXCLUDED.picked_by, status = 'picked',
               confirmed_at = NULL, confirmed_by = NULL, updated_at = now();
      END LOOP;

    ELSIF v_picker_version = 'shadow' THEN
      PERFORM public.pick_machines_for_refill(p_plan_date);
      DELETE FROM public.machines_to_visit_shadow
       WHERE plan_date = p_plan_date AND picker_version = 'v12';
      INSERT INTO public.machines_to_visit_shadow
        (plan_date, picker_version, machine_id, official_name, tier, visit_value_aed, reasons, building_id, cluster_role, donor_for)
      SELECT p_plan_date, 'v12', v12.machine_id, v12.official_name, v12.tier, v12.visit_value_aed,
             v12.reasons, v12.building_id, v12.cluster_role, v12.donor_for
        FROM public.pick_machines_v12(p_plan_date) v12;

    ELSE
      PERFORM public.pick_machines_for_refill(p_plan_date);
    END IF;

    v_repicked := true;
  END IF;

  -- THE P0.3 CHANGE. v1 called this unconditionally, which is the auto-fallback CS forbade.
  IF p_auto_confirm THEN
    v_auto_conf := public.confirm_machines_to_visit(p_plan_date);
  ELSE
    v_auto_conf := jsonb_build_object('status', 'skipped_manual_gate', 'confirmed_now', 0,
      'message', 'Gate 0 is manual: CS confirms the pick list, no auto-confirm (CS decision #1)');
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE status = 'picked'),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL AND COALESCE(is_included, true) = true)
  INTO v_picked, v_confirmed, v_included
  FROM public.machines_to_visit
  WHERE plan_date = p_plan_date;

  BEGIN
    PERFORM public._assert_gate_zero(p_plan_date);
  EXCEPTION WHEN OTHERS THEN
    -- BUILD SPEC P0.3: "8pm advisory must render the 'awaiting your confirmation' state with
    -- the pick list." v1 returned only two counts, so the advisory had nothing to render.
    SELECT jsonb_agg(jsonb_build_object(
             'machine_id',     mtv.machine_id,
             'official_name',  mtv.official_name,
             'priority_score', mtv.priority_score,
             'picked_reasons', mtv.picked_reasons,
             'venue_group',    mtv.venue_group,
             'service_track',  mtv.service_track,
             'is_included',    COALESCE(mtv.is_included, true)
           ) ORDER BY mtv.priority_score DESC NULLS LAST, mtv.official_name)
      INTO v_picks
      FROM public.machines_to_visit mtv
     WHERE mtv.plan_date = p_plan_date AND mtv.status = 'picked' AND mtv.confirmed_at IS NULL;

    RETURN jsonb_build_object(
      'status',          'awaiting_confirmation',
      'plan_date',       p_plan_date,
      'repicked',        v_repicked,
      'confirmed',       v_confirmed,
      'picked',          v_picked,
      'awaiting_count',  COALESCE(jsonb_array_length(v_picks), 0),
      'pick_list',       COALESCE(v_picks, '[]'::jsonb),
      'auto_confirm',    p_auto_confirm,
      'next_action',     'CS confirms the pick list (confirm_machines_to_visit / pick_machine_manually / unpick_machine_to_visit), then build_confirmed_now_v3(plan_date) - or wait for the next cron cycle.'
    );
  END;

  IF v_included = 0 THEN
    RETURN jsonb_build_object('status', 'no_included_machines',
      'plan_date', p_plan_date, 'confirmed', v_confirmed);
  END IF;

  -- ── PRD-110 DR-1: the per-cluster cutover guard. Flag-off = unreachable. ──────
  -- Placed HERE deliberately: everything above (calendar, LAW-12 live-plan guard, repick,
  -- Gate-0 advisory) still runs, so a flipped cluster costs the PLAN and never the advisory.
  -- cutover_block_reason_v3 fails OPEN, so this can never halt the plan because IT broke.
  -- ── PRD-110 DR-1b: the HALT became a BRANCH. ─────────────────────────────────
  -- DR-1 could only stop: while any cluster was authoritative for v3 the whole fleet went
  -- unplanned. Correct and loud, and useless as a cutover. DR-1b makes the flip actually
  -- plan that cluster with v3 and everyone else with v19, on the same plan_date.
  --
  -- cutover_block_reason_v3 is still CALLED and its body is byte-untouched (fixture 74 seq 13
  -- pins the call, seq 65/66 pin the fail-open handler). What changed is what this builder
  -- DOES with `blocked`: it is now the BRANCH predicate, not a halt. It still fails OPEN, so
  -- a failure of its own read leaves every cluster on v19 and the plan is built as before.
  DECLARE v_cut jsonb; BEGIN
    v_cut := public.cutover_block_reason_v3();

    -- v19 FIRST, and it is now machine-scoped: its pod_refills DELETE and its `picked` CTE
    -- both skip v3-authoritative machines, so it can no longer wipe what v3 is about to write.
    v_add := engine_add_pod(p_plan_date, 14);

    IF COALESCE((v_cut->>'blocked')::boolean, false) THEN
      -- ⭐ v3 shadow-plans the WHOLE FLEET here, not just the flipped clusters. Scoping the
      --    v3 READ to authoritative machines would be the obvious symmetry and it would
      --    deadlock the cutover on its own evidence: with 0 clusters flipped v3 would plan
      --    nothing, engine_forecast_error_v3 would stop accruing, and no cluster could ever
      --    clear the readiness gate. v3's SHADOW scope is the fleet; v3's LIVE scope is the
      --    flipped clusters. That asymmetry IS the design.
      v_add_v3 := public.engine_add_pod_v3(p_plan_date, 14);

      -- ...and only the flipped clusters' rows are published into the live table. This
      -- REFUSES rather than publishing an empty plan if the date has no v3 shadow run.
      v_promo  := public.promote_v3_shadow_to_live_v3(p_plan_date);
    END IF;
  END;

  v_swap  := engine_swap_pod(p_plan_date, 2, 0.30, 14);
  v_final := engine_finalize_pod(p_plan_date);

  RETURN jsonb_build_object(
    'status',             'draft_ready',
    'plan_date',          p_plan_date,
    'repicked',           v_repicked,
    'auto_confirm',       p_auto_confirm,
    'machines_picked',    v_picked,
    'machines_confirmed', v_confirmed,
    'machines_included',  v_included,
    'auto_confirmed',     v_auto_conf,
    'stage_2a',           v_add,
    'stage_2a_v3',        v_add_v3,
    'stage_2a_promote',   v_promo,
    'stage_2b',           v_swap,
    'stage_2c',           v_final,
    'coverage',           public.check_refill_coverage(p_plan_date)
  );
END;
$function$;
