-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- Read-only preflight gate: 12 versioned invariants (INV-01..12) against a plan_date. STABLE, SECURITY INVOKER, no overload.

CREATE OR REPLACE FUNCTION public.preflight_refill_plan(p_plan_date date)
 RETURNS TABLE(verdict text, violations jsonb, warnings jsonb, checked_at timestamp with time zone, invariant_versions jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb := '[]'::jsonb;
  v_viol jsonb;
  v_warn jsonb;
  v_evian uuid := '990461ff-ff92-4b3f-aedb-cde0e951aaf8';
BEGIN
  WITH
  -- ── the plan under test ────────────────────────────────────────────────
  plan AS (
    SELECT r.id, r.plan_date, upper(trim(r.action)) AS act, r.quantity,
           r.machine_name, r.shelf_code, r.pod_product_name, r.boonz_product_name,
           r.source_origin, r.from_machine_id, r.current_stock, r.max_stock, r.comment,
           COALESCE(r.machine_id, (SELECT m.machine_id FROM machines m WHERE m.official_name = r.machine_name)) AS machine_id,
           COALESCE(r.pod_product_id, (SELECT pp.pod_product_id FROM pod_products pp
                      WHERE lower(trim(pp.pod_product_name)) = lower(trim(r.pod_product_name)) LIMIT 1)) AS pod_product_id,
           COALESCE(r.boonz_product_id, (SELECT bp.product_id FROM boonz_products bp
                      WHERE lower(trim(bp.boonz_product_name)) = lower(trim(r.boonz_product_name)) LIMIT 1)) AS boonz_product_id,
           regexp_replace(r.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2') AS shelf_norm
      FROM refill_plan_output r
     WHERE r.plan_date = p_plan_date AND r.operator_status = 'approved'
  ),
  -- ── WH truth, deduped by batch BEFORE any mapping join ─────────────────
  wh_dedup AS (
    SELECT DISTINCT v.wh_inventory_id, v.boonz_product_id, v.warehouse_id,
           v.warehouse_stock, v.reserved_for_machine_id
      FROM v_wh_pickable v
  ),
  wh_by_boonz AS (
    SELECT boonz_product_id, SUM(warehouse_stock)::int AS units_any_wh
      FROM wh_dedup GROUP BY 1
  ),
  -- ── INV-01/02 name family: every boonz variant reachable from the pod by
  -- ACTIVE mapping at ANY scope, plus same product_family_id. Deliberately
  -- ignores machine scoping - scoping may pick the SKU, never hide siblings.
  fam AS (
    SELECT DISTINCT pm.pod_product_id, pm.boonz_product_id
      FROM product_mapping pm WHERE pm.status = 'Active'
    UNION
    SELECT DISTINCT pm.pod_product_id, b2.product_id
      FROM product_mapping pm
      JOIN boonz_products b1 ON b1.product_id = pm.boonz_product_id AND b1.product_family_id IS NOT NULL
      JOIN boonz_products b2 ON b2.product_family_id = b1.product_family_id
     WHERE pm.status = 'Active'
  ),
  fam_units AS (
    SELECT f.pod_product_id,
           SUM(COALESCE(w.units_any_wh,0))::int AS name_units,
           COUNT(DISTINCT f.boonz_product_id)   AS variants
      FROM fam f LEFT JOIN wh_by_boonz w ON w.boonz_product_id = f.boonz_product_id
     GROUP BY 1
  ),
  -- scoped resolution = what the engine actually picks for this machine
  scoped AS (
    SELECT p.id, p.machine_id, p.pod_product_id,
           (SELECT pm.boonz_product_id FROM product_mapping pm
             WHERE pm.pod_product_id = p.pod_product_id AND pm.status='Active'
               AND (pm.machine_id = p.machine_id OR pm.machine_id IS NULL)
             ORDER BY (pm.machine_id = p.machine_id) DESC NULLS LAST, pm.is_global_default DESC, pm.updated_at DESC
             LIMIT 1) AS scoped_boonz
      FROM plan p
  ),
  present AS (
    SELECT machine_id, pod_product_id FROM slot_lifecycle
     WHERE archived=false AND is_current=true AND pod_product_id IS NOT NULL
    UNION
    SELECT machine_id, pod_product_id FROM v_live_shelf_stock
     WHERE pod_product_id IS NOT NULL AND current_stock > 0
  ),
  dd AS (
    SELECT DISTINCT machine_id, pod_product_id FROM slot_lifecycle
     WHERE archived=false AND is_current=true AND signal='DOUBLE DOWN'
  ),

  -- ══ INV-01 name-level WH coverage (07-29 Extra Gum) ════════════════════
  inv01 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-01','severity','violation','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected', format('name-level pickable >= %s', p.quantity),
      'found', format('%s units across %s variant(s)', COALESCE(fu.name_units,0), COALESCE(fu.variants,0)),
      'fix_path','Raise a purchase order, or reduce the planned quantity. If units exist under a sibling variant, re-point the machine-scoped product_mapping row.') AS v
      FROM plan p LEFT JOIN fam_units fu ON fu.pod_product_id = p.pod_product_id
     WHERE p.act IN ('REFILL','ADD NEW') AND COALESCE(p.quantity,0) > 0
       AND COALESCE(p.source_origin::text,'warehouse') = 'warehouse'
       AND COALESCE(fu.name_units,0) < p.quantity
  ),
  -- ══ INV-02 mapping shadow detector (07-29) - WARNING ═══════════════════
  inv02 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-02','severity','warning','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected','machine-scoped mapping does not hide sibling stock',
      'found', format('scoped SKU has %s units; %s units exist across the name family (%s variants)',
                      COALESCE(sw.units_any_wh,0), COALESCE(fu.name_units,0), COALESCE(fu.variants,0)),
      'fix_path','Review product_mapping scope for this pod: a machine-scoped Active row is shadowing a global sibling that holds stock.') AS v
      FROM plan p
      JOIN scoped s ON s.id = p.id
      LEFT JOIN wh_by_boonz sw ON sw.boonz_product_id = s.scoped_boonz
      LEFT JOIN fam_units fu ON fu.pod_product_id = p.pod_product_id
     WHERE p.act IN ('REFILL','ADD NEW')
       -- PRD-109 INV-02 tightened: the PRD asks for GLOBAL-ONLY siblings WITH stock that the
       -- machine scope EXCLUDES (the Extra Gum shape), not merely "family total > scoped SKU"
       -- which is true of almost any multi-flavour pod and produced 80 benign warnings.
       AND EXISTS (SELECT 1 FROM product_mapping pmx
                    WHERE pmx.pod_product_id = p.pod_product_id AND pmx.status = 'Active'
                      AND pmx.machine_id = p.machine_id)
       AND EXISTS (SELECT 1 FROM fam f2
                    JOIN wh_by_boonz w2 ON w2.boonz_product_id = f2.boonz_product_id
                                       AND w2.units_any_wh > 0
                    WHERE f2.pod_product_id = p.pod_product_id
                      AND f2.boonz_product_id IS DISTINCT FROM s.scoped_boonz
                      AND NOT EXISTS (SELECT 1 FROM product_mapping pmy
                                       WHERE pmy.pod_product_id = p.pod_product_id
                                         AND pmy.status = 'Active'
                                         AND pmy.machine_id = p.machine_id
                                         AND pmy.boonz_product_id = f2.boonz_product_id))
  ),
  -- ══ INV-03 in-machine duplicate adds (07-29 Barebells/CCZ) ═════════════
  inv03 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-03','severity','violation','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected','ADD NEW only for a pod not already on the machine',
      'found','pod already has a live facing on this machine and it is not flagged DOUBLE DOWN',
      'fix_path','Drop this ADD NEW line, or set the existing facing to DOUBLE DOWN in slot_lifecycle if a second facing is genuinely intended.') AS v
      FROM plan p
      JOIN present pr ON pr.machine_id = p.machine_id AND pr.pod_product_id = p.pod_product_id
      LEFT JOIN dd ON dd.machine_id = p.machine_id AND dd.pod_product_id = p.pod_product_id
     WHERE p.act = 'ADD NEW' AND dd.machine_id IS NULL
  ),
  -- ══ INV-04 orphaned swap legs (07-29 MC A15) ═══════════════════════════
  -- A REMOVE on a shelf whose paired ADD NEW legs have ALL died (not_filled or
  -- skipped) at dispatch. Flag before the driver departs, not after.
  inv04 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-04','severity','violation','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected','a REMOVE ships only when its paired swap-in is filled',
      'found','every ADD NEW on this shelf resolved not_filled or skipped; removing would leave the shelf EMPTY',
      'fix_path','skip_dispatch_line(dispatch_id, reason) on the REMOVE leg to keep the current product, and redo the swap next plan.') AS v
      FROM plan p
     WHERE p.act = 'REMOVE' AND p.machine_id IS NOT NULL AND p.shelf_code IS NOT NULL
       AND EXISTS (SELECT 1 FROM refill_dispatching a
                    JOIN shelf_configurations sc ON sc.shelf_id = a.shelf_id
                   WHERE a.machine_id = p.machine_id AND a.dispatch_date = p_plan_date
                     AND sc.shelf_code = p.shelf_norm AND a.action = 'Add New'
                     AND COALESCE(a.cancelled,false)=false AND COALESCE(a.include,true)=true)
       AND NOT EXISTS (SELECT 1 FROM refill_dispatching a
                    JOIN shelf_configurations sc ON sc.shelf_id = a.shelf_id
                   WHERE a.machine_id = p.machine_id AND a.dispatch_date = p_plan_date
                     AND sc.shelf_code = p.shelf_norm AND a.action = 'Add New'
                     AND COALESCE(a.cancelled,false)=false AND COALESCE(a.include,true)=true
                     AND COALESCE(a.skipped,false)=false
                     AND a.pack_outcome IS DISTINCT FROM 'not_filled'::pack_outcome_enum)
  ),
  -- ══ INV-05 suppressed M2W (07-28 CS rule) ══════════════════════════════
  inv05 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-05','severity','violation','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected','zero Machine To Warehouse rows with qty > 0 (M2W is banned as an auto-outcome)',
      'found', format('M2W row with quantity %s', p.quantity),
      'fix_path','Replace with a qty-0 no_viable_swap_candidate row plus a procurement alert, or reject the line explicitly.') AS v
      FROM plan p
     WHERE p.act IN ('MACHINE TO WAREHOUSE','M2W') AND COALESCE(p.quantity,0) > 0
  ),
  -- ══ INV-06 conservation ════════════════════════════════════════════════
  -- Parent pod_refill_plan REMOVE/M2W qty must equal the sum of its approved
  -- children. Superseded/excluded legs are excluded by the approved filter.
  -- ══ INV-06 conservation (v2 - PRD-110 P0.6(d)) ══════════════════════════
  -- A STITCHED parent REMOVE/M2W leg must equal the sum of its dispatch legs.
  -- v1 raised three false-positive classes. Measured over ALL 427 historical
  -- violations on 2026-07-30: 156 superseded/voided parents + 98 draft parents +
  -- 7 whose children existed but were not operator_status='approved'. v2 corrects
  -- the predicate and does NOT weaken the sum test, so the 40 genuine mismatches
  -- still fail (e.g. USH-1008 A14 2026-07-28, parent 8 vs legs 3+2+2=7).
  -- Golden fixture 10 pins BOTH directions - S1/S2/S5/S6 must clear, S4 must stay red.
  --  (1) parents: status = 'stitched' only. draft/approved parents have not been
  --      stitched yet, so they cannot have legs; superseded/voided parents were
  --      replaced and their legs were re-issued under the successor. Keyed on
  --      status, NOT stitched_at: 5 live non-stitched rows carry a stray
  --      stitched_at, while status='stitched' <=> stitched_at IS NOT NULL (196/196).
  --      This also collapses each key to exactly ONE removal parent (measured: zero
  --      keys hold two stitched removal parents), so the lumped-children comparison
  --      below is unambiguous.
  --  (2) children: read refill_plan_output directly, counting operator_status
  --      IN ('approved','expired'). v1 summed the 'approved'-only `plan` CTE, so a
  --      leg that shipped and later aged to 'expired' made its parent look unfilled.
  --      'rejected' stays excluded - a rejected leg genuinely never ships.
  --  (3) join on the uuid keys refill_plan_output already carries, falling back to
  --      name/shelf_code resolution only where they are NULL (74 legacy rows).
  --      Both sides of the shelf_code comparison get the A1 -> A01 zero-pad.
  --  Removal family stays LUMPED (REMOVE + MACHINE TO WAREHOUSE counted together).
  --  Live data forbids strict action-matching: of 26 non-superseded M2W parents, 21
  --  have no leg at all, 2 have 'Remove' legs and only 1 has 'Machine To Warehouse',
  --  so matching action-for-action would manufacture a NEW false-positive class.
  inv06 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-06','severity','violation','machine',m.official_name,
      'shelf_code',sc.shelf_code,'pod_product_name',pp.pod_product_name,
      'boonz_product_name',NULL,
      'expected', format('children sum = parent qty %s', prp.qty),
      'found', format('children sum %s', COALESCE(g.children,0)),
      'fix_path','Re-run the stitch for this machine; if it persists, inspect stitch_leakage for this plan_date.') AS v
      FROM pod_refill_plan prp
      JOIN machines m ON m.machine_id = prp.machine_id
      LEFT JOIN shelf_configurations sc ON sc.shelf_id = prp.shelf_id
      LEFT JOIN pod_products pp ON pp.pod_product_id = prp.pod_product_id
      LEFT JOIN (
        SELECT COALESCE(r.machine_id,     m3.machine_id)     AS machine_id,
               COALESCE(r.shelf_id,       sc3.shelf_id)      AS shelf_id,
               COALESCE(r.pod_product_id, pp3.pod_product_id) AS pod_product_id,
               SUM(r.quantity)::int                          AS children
          FROM refill_plan_output r
          LEFT JOIN machines m3
                 ON r.machine_id IS NULL AND m3.official_name = r.machine_name
          LEFT JOIN shelf_configurations sc3
                 ON r.shelf_id IS NULL
                AND sc3.machine_id = COALESCE(r.machine_id, m3.machine_id)
                AND regexp_replace(sc3.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2')
                  = regexp_replace(r.shelf_code,   '^([A-Z])([0-9])$', '\1' || '0' || '\2')
          LEFT JOIN pod_products pp3
                 ON r.pod_product_id IS NULL
                AND lower(trim(pp3.pod_product_name)) = lower(trim(r.pod_product_name))
         WHERE r.plan_date = p_plan_date
           AND upper(trim(r.action)) IN ('REMOVE','MACHINE TO WAREHOUSE')
           AND r.operator_status IN ('approved','expired')
         GROUP BY 1,2,3
      ) g ON g.machine_id     = prp.machine_id
         AND g.shelf_id       = prp.shelf_id
         AND g.pod_product_id = prp.pod_product_id
     WHERE prp.plan_date = p_plan_date
       AND prp.action IN ('REMOVE','M2W')
       AND prp.qty > 0
       AND prp.status = 'stitched'
       AND prp.qty <> COALESCE(g.children,0)
  ),
  -- ══ INV-07 slot-guard parity ═══════════════════════════════════════════
  inv07 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-07','severity','violation','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected','planned pod matches the WEIMI physical slot, or is one leg of a same-shelf swap pair',
      'found','no WEIMI slot on this shelf carries this pod, and no paired swap leg exists on the shelf',
      'fix_path','Run the WEIMI resolver / reconcile for this machine before committing (assert_weimi_slot_match names the offending slot).') AS v
      FROM plan p
     WHERE p.act = 'REFILL' AND p.machine_id IS NOT NULL AND p.pod_product_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM v_live_shelf_stock vls
          WHERE vls.machine_id = p.machine_id AND vls.pod_product_id = p.pod_product_id)
       AND NOT EXISTS (
         SELECT 1 FROM plan p3 WHERE p3.machine_id = p.machine_id
           AND p3.shelf_norm = p.shelf_norm AND p3.act IN ('ADD NEW','REMOVE'))
  ),
  -- ══ INV-08 pack-progress parity (structural post-PRD-107; assert anyway) ═
  inv08 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-08','severity','violation','machine',v.machine_name,
      'shelf_code',NULL,'pod_product_name',NULL,'boonz_product_name',NULL,
      'expected','v_dispatch_pack_progress.ready_to_pack_close equals the confirm_machine_packed predicate',
      'found', format('view ready=%s but unresolved packable count=%s', v.ready_to_pack_close, v.packable_n - v.resolved_n),
      'fix_path','Regression in PRD-107 parity. Re-check v_dispatch_pack_progress.resolved_n against confirm_machine_packed.') AS v
      FROM v_dispatch_pack_progress v
     WHERE v.dispatch_date = p_plan_date
       AND v.ready_to_pack_close <> (v.packable_n = v.resolved_n)
  ),
  -- ══ INV-09 guardrail products ══════════════════════════════════════════
  inv09 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-09','severity','violation','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected','no Evian 1L swap-in, no decommission-intent product added',
      'found', CASE WHEN p.pod_product_id = v_evian THEN 'Evian 1L planned as a swap-in'
                    ELSE 'product has a queued or in-progress decommission intent' END,
      'fix_path','Drop this line. Evian 1L is a standing CS guardrail; decommission intents must be cleared in strategic_intents before re-planning.') AS v
      FROM plan p
     WHERE p.act IN ('ADD NEW','REFILL')
       AND ( p.pod_product_id = v_evian
          OR EXISTS (SELECT 1 FROM strategic_intents si
                      WHERE si.intent_type='decommission' AND si.status IN ('queued','in_progress')
                        AND si.scope_pod_product_id = p.pod_product_id) )
  ),
  -- ══ INV-10 empty-shelf outcome (the ghost-stockout absence detector) ════
  -- A live shelf projected to end at 0 with NO plan line at all. This is the
  -- class the Extra Gum incident belongs to: the symptom was an ABSENCE (the
  -- stitch dropped the line as total_wh_stockout), not a bad line. Reports the
  -- name-level units so a real stockout is distinguishable from a shadowed one.
  inv10 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-10','severity','violation','machine',m.official_name,
      'shelf_code',vls.slot_name,'pod_product_name',pp.pod_product_name,
      'boonz_product_name',NULL,
      'expected','a shelf heading to zero has an ADD/REFILL line or an explicit decision',
      'found', format('stock %s of %s and no plan line; %s units available at name level across %s variant(s)',
                      vls.current_stock, vls.max_stock, COALESCE(fu.name_units,0), COALESCE(fu.variants,0)),
      'fix_path', CASE WHEN COALESCE(fu.name_units,0) > 0
                       THEN 'Stock EXISTS at name level - this is a shadowed stockout, not a real one. Check product_mapping scope, then re-stitch.'
                       ELSE 'Genuine stockout. Raise a purchase order or record an explicit decision to leave the shelf empty.' END) AS v
      FROM v_live_shelf_stock vls
      JOIN machines m ON m.machine_id = vls.machine_id
      JOIN pod_products pp ON pp.pod_product_id = vls.pod_product_id
      LEFT JOIN fam_units fu ON fu.pod_product_id = vls.pod_product_id
     WHERE vls.pod_product_id IS NOT NULL
       AND COALESCE(vls.is_enabled,true) = true AND COALESCE(vls.is_broken,false) = false
       AND vls.current_stock = 0
       AND EXISTS (SELECT 1 FROM plan p4 WHERE p4.machine_id = vls.machine_id)
       AND NOT EXISTS (SELECT 1 FROM plan p5
                        WHERE p5.machine_id = vls.machine_id
                          AND p5.pod_product_id = vls.pod_product_id
                          AND p5.act IN ('REFILL','ADD NEW'))
  ),
  -- ══ INV-11 stale binding / drift - WARNING ═════════════════════════════
  inv11 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-11','severity','warning','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected','pod_inventory identity agrees with WEIMI for this shelf',
      'found','planned pod is not present on any WEIMI slot of this machine',
      'fix_path','Run the drift resolver / reconcile for this machine (WEIMI is the only slot-product identity source).') AS v
      FROM plan p
     WHERE p.machine_id IS NOT NULL AND p.pod_product_id IS NOT NULL
       -- PRD-109: differentiated from INV-07. INV-07 owns REFILL slot-guard parity;
       -- INV-11 owns genuine pod_inventory-vs-WEIMI DRIFT: WEIMI no longer shows the pod
       -- on this machine, yet pod_inventory still carries Active stock for it. Sharing
       -- INV-07 predicate made INV-11 a noisy duplicate of the same fact.
       AND p.act = 'REMOVE'
       AND NOT EXISTS (SELECT 1 FROM v_live_shelf_stock vls
                        WHERE vls.machine_id = p.machine_id AND vls.pod_product_id = p.pod_product_id)
       AND EXISTS (SELECT 1 FROM pod_inventory pi
                    WHERE pi.machine_id = p.machine_id
                      AND pi.boonz_product_id = p.boonz_product_id
                      AND pi.status = 'Active' AND COALESCE(pi.current_stock,0) > 0)
  ),
  -- ══ INV-12 wh routing ══════════════════════════════════════════════════
  inv12 AS (
    SELECT jsonb_build_object(
      'invariant_id','INV-12','severity','violation','machine',p.machine_name,
      'shelf_code',p.shelf_code,'pod_product_name',p.pod_product_name,
      'boonz_product_name',p.boonz_product_name,
      'expected','line resolves to a serving warehouse holding the units',
      'found', CASE WHEN m2.primary_warehouse_id IS NULL THEN 'machine has no primary_warehouse_id'
                    ELSE format('no pickable units in the serving warehouses, though %s units exist fleet-wide at name level',
                                COALESCE(fu.name_units,0)) END,
      'fix_path','Set machines.primary_warehouse_id, or transfer stock into the serving warehouse (VOX routes to MM/MCC, otherwise CENTRAL).') AS v
      FROM plan p
      JOIN machines m2 ON m2.machine_id = p.machine_id
      LEFT JOIN fam_units fu ON fu.pod_product_id = p.pod_product_id
     WHERE p.act IN ('REFILL','ADD NEW') AND COALESCE(p.quantity,0) > 0
       AND COALESCE(p.source_origin::text,'warehouse') = 'warehouse'
       AND ( m2.primary_warehouse_id IS NULL
          OR NOT EXISTS (
               SELECT 1 FROM wh_dedup w
                JOIN fam f2 ON f2.boonz_product_id = w.boonz_product_id
               WHERE f2.pod_product_id = p.pod_product_id
                 AND w.warehouse_id IN (m2.primary_warehouse_id, m2.secondary_warehouse_id)
                 AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = p.machine_id)) )
  ),
  all_rows AS (
    SELECT v FROM inv01 UNION ALL SELECT v FROM inv02 UNION ALL SELECT v FROM inv03
    UNION ALL SELECT v FROM inv04 UNION ALL SELECT v FROM inv05 UNION ALL SELECT v FROM inv06
    UNION ALL SELECT v FROM inv07 UNION ALL SELECT v FROM inv08 UNION ALL SELECT v FROM inv09
    UNION ALL SELECT v FROM inv10 UNION ALL SELECT v FROM inv11 UNION ALL SELECT v FROM inv12
  )
  SELECT COALESCE(jsonb_agg(a.v ORDER BY a.v->>'invariant_id'), '[]'::jsonb) INTO v_rows
    FROM all_rows a;

  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_viol
    FROM jsonb_array_elements(v_rows) x WHERE x->>'severity' = 'violation';
  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_warn
    FROM jsonb_array_elements(v_rows) x WHERE x->>'severity' = 'warning';

  RETURN QUERY SELECT
    CASE WHEN jsonb_array_length(v_viol) > 0 THEN 'FAIL'
         WHEN jsonb_array_length(v_warn) > 0 THEN 'PASS_WITH_WARNINGS'
         ELSE 'PASS' END,
    v_viol, v_warn, now(),
    jsonb_build_object(
      'INV-01','v1','INV-02','v1','INV-03','v1','INV-04','v1','INV-05','v1','INV-06','v2',
      'INV-07','v1','INV-08','v1','INV-09','v1','INV-10','v1','INV-11','v1','INV-12','v1',
      'set_version','v2','shipped','2026-07-30');
END;
$function$
