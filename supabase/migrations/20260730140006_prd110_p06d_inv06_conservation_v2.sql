-- PRD-110 P0.6(d) - INV-06 conservation invariant, v1 -> v2.
-- Cody: Approve with revisions (Articles 1,3,5,12,13,14,16). Revisions done in
-- 20260730140005: rollback body frozen in golden.snapshots, fixture 10 hardened.
-- Proven by golden fixture 10 (2030-01-11): RED 6/5 before, GREEN 11/0 after.
-- Fleet effect: INV-06 rows across all 49 removal-bearing plan_dates 427 -> 86.
-- Both known true positives survive verbatim (USH-1008 A14 8/7, ADDMIND-1007 A13 3/4).
--
-- Edited by NAMED SUBSTITUTION of the inv06 CTE region (anchors verified unique) rather
-- than retyping 21k chars of body - the Wave-1 engine-edit pattern. Both anchors and the
-- version-registry strings are asserted present BEFORE the rewrite, and the result is
-- re-parsed by CREATE OR REPLACE, so a missed anchor fails loudly instead of silently.

DO $mig$
DECLARE
  v_src   text;
  v_new   text;
  v_s     int;
  v_e     int;
  v_cte   text;
BEGIN
  SELECT p.prosrc INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'preflight_refill_plan';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'preflight_refill_plan not found';
  END IF;

  v_s := position('  inv06 AS (' in v_src);
  v_e := position('  -- ══ INV-07' in v_src);
  IF v_s = 0 OR v_e = 0 OR v_e <= v_s THEN
    RAISE EXCEPTION 'INV-06 anchors not found or out of order (inv06=%, inv07=%)', v_s, v_e;
  END IF;
  IF position('''INV-06'',''v1''' in v_src) = 0 THEN
    RAISE EXCEPTION 'INV-06 version-registry anchor not found';
  END IF;

  v_cte := $cte$  -- ══ INV-06 conservation (v2 - PRD-110 P0.6(d)) ══════════════════════════
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
$cte$;

  v_new := left(v_src, v_s - 1) || v_cte || substr(v_src, v_e);

  -- bump the reported invariant version so consumers can see which set they ran
  v_new := replace(v_new, '''INV-06'',''v1''', '''INV-06'',''v2''');
  v_new := replace(v_new,
    '''set_version'',''v1'',''shipped'',''2026-07-29''',
    '''set_version'',''v2'',''shipped'',''2026-07-30''');

  IF position('prp.status = ''stitched''' in v_new) = 0
     OR position('''INV-06'',''v2''' in v_new) = 0 THEN
    RAISE EXCEPTION 'INV-06 v2 substitution did not produce the expected body';
  END IF;

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.preflight_refill_plan(p_plan_date date)
       RETURNS TABLE(verdict text, violations jsonb, warnings jsonb,
                     checked_at timestamptz, invariant_versions jsonb)
       LANGUAGE plpgsql STABLE SET search_path = public AS %L', v_new);
END $mig$;

-- post-conditions: the live body is v2, still STABLE, still not SECURITY DEFINER
DO $chk$
DECLARE r record;
BEGIN
  SELECT p.provolatile, p.prosecdef,
         position('prp.status = ''stitched''' in p.prosrc) AS has_fix,
         position('''INV-06'',''v2''' in p.prosrc)         AS has_ver
    INTO r
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'preflight_refill_plan';

  IF r.provolatile <> 's' OR r.prosecdef OR r.has_fix = 0 OR r.has_ver = 0 THEN
    RAISE EXCEPTION 'INV-06 v2 post-condition failed (volatile=%, secdef=%, fix=%, ver=%)',
                    r.provolatile, r.prosecdef, r.has_fix, r.has_ver;
  END IF;
END $chk$;
