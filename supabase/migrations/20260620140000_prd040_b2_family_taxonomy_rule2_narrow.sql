-- PRD-040 B2: curated product-family taxonomy + boonz backfill + Rule-2 NARROW flip to family_id.
-- Forward-only. Supersede-not-delete (the same-brand Rule-2 rows are DEACTIVATED, not removed). No _v2, no deletes.
-- CS decisions 2026-06-20: brand-fallback families for the non-pod-inherited products (all 307 family-keyed);
-- NARROW Rule-2 scope (flip only groups 2/3/4/7 to family_id, behaviour-preserving; groups 1/5/6 cross-brand stay).
-- swaps_enabled untouched. engine_swap_pod / engine_add_pod untouched.
--
-- Family id-spaces: boonz_products.product_family_id FKs to curated_product_families (EMPTY today);
-- pod_products.product_family_id FKs to product_families (jaccard, 102). We populate curated from the
-- pod-inherited family NAMES (+ brand fallbacks) so boonz gets a curated id in its own FK space.

-- 1. Supersede support: coexistence_rules has no is_active column today.
ALTER TABLE public.coexistence_rules ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- 2. Populate curated_product_families: pod-inherited family names that have >=1 boonz member, + brand fallbacks.
INSERT INTO public.curated_product_families (product_family_id, family_name, display_name, is_active)
SELECT gen_random_uuid(), fam, fam, true FROM (
  SELECT DISTINCT pf.family_name AS fam
    FROM public.product_families pf
   WHERE EXISTS (
     SELECT 1 FROM public.boonz_products bp
      JOIN public.product_mapping pm ON pm.boonz_product_id=bp.product_id AND pm.status='Active'
      JOIN public.pod_products pp ON pp.pod_product_id=pm.pod_product_id
      WHERE pp.product_family_id = pf.product_family_id)
  UNION
  SELECT DISTINCT 'BRAND: '||bp.product_brand
    FROM public.boonz_products bp
   WHERE bp.product_brand IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.product_mapping pm JOIN public.pod_products pp ON pp.pod_product_id=pm.pod_product_id
        WHERE pm.boonz_product_id=bp.product_id AND pm.status='Active' AND pp.product_family_id IS NOT NULL)
) f
ON CONFLICT DO NOTHING;

-- 3. Backfill boonz_products.product_family_id: dominant pod-inherited curated family, else brand-fallback family.
UPDATE public.boonz_products bp SET product_family_id = sub.cfid
FROM (
  SELECT bp2.product_id,
    COALESCE(
      (SELECT cpf.product_family_id FROM public.product_mapping pm
         JOIN public.pod_products pp ON pp.pod_product_id=pm.pod_product_id
         JOIN public.product_families pf ON pf.product_family_id=pp.product_family_id
         JOIN public.curated_product_families cpf ON cpf.family_name=pf.family_name
        WHERE pm.boonz_product_id=bp2.product_id AND pm.status='Active' AND pp.product_family_id IS NOT NULL
        GROUP BY cpf.product_family_id ORDER BY count(*) DESC, cpf.product_family_id LIMIT 1),
      (SELECT cpf.product_family_id FROM public.curated_product_families cpf WHERE cpf.family_name='BRAND: '||bp2.product_brand)
    ) AS cfid
  FROM public.boonz_products bp2
) sub
WHERE bp.product_id=sub.product_id AND sub.cfid IS NOT NULL AND bp.product_family_id IS NULL;

-- 4. _coexistence_blocks: add a product_family_id match type + honor is_active. Forward CREATE OR REPLACE.
--    (Reproduces the live v12/PRD-037 body; adds cand.fam / onm.fam, the family match clause, and cr.is_active.)
CREATE OR REPLACE FUNCTION public._coexistence_blocks(p_machine_id uuid, p_cand_boonz uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH cand AS (
    SELECT bp.product_id AS boonz_id, bp.product_brand AS brand, bp.brand_owner AS owner, bp.boonz_product_name AS nm, bp.product_family_id AS fam
    FROM public.boonz_products bp WHERE bp.product_id = p_cand_boonz
  ),
  mv AS (SELECT m.venue_group FROM public.machines m WHERE m.machine_id = p_machine_id),
  onm AS (
    SELECT DISTINCT bp.product_brand AS brand, bp.brand_owner AS owner, bp.boonz_product_name AS nm, bp.product_family_id AS fam
    FROM (
      SELECT pm.boonz_product_id FROM public.slot_lifecycle sl
        JOIN public.product_mapping pm ON pm.pod_product_id = sl.pod_product_id AND pm.status='Active'
       WHERE sl.machine_id = p_machine_id AND sl.archived=false AND sl.is_current=true
      UNION
      SELECT pm.boonz_product_id FROM public.v_live_shelf_stock vls
        JOIN public.product_mapping pm ON pm.pod_product_id = vls.pod_product_id AND pm.status='Active'
       WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
    ) b JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
  )
  SELECT
    EXISTS (
      SELECT 1 FROM cand c, mv
      JOIN public.coexistence_rules cr ON cr.rule_group='rule1_tccc_venue_exclusion' AND cr.is_active
      WHERE c.owner = cr.a_match_value AND mv.venue_group = ANY (cr.venue_groups)
    )
    OR
    EXISTS (
      SELECT 1 FROM cand c
      JOIN public.coexistence_rules cr ON cr.scope='machine' AND cr.rule_type='hard' AND cr.is_active
      JOIN onm o ON
        ( (cr.a_match_type='product_brand'      AND c.brand = cr.a_match_value) OR
          (cr.a_match_type='brand_owner'        AND c.owner = cr.a_match_value) OR
          (cr.a_match_type='name'               AND c.nm    = cr.a_match_value) OR
          (cr.a_match_type='product_id'         AND c.boonz_id::text = cr.a_match_value) OR
          (cr.a_match_type='family_id'  AND c.fam IS NOT NULL AND c.fam::text = cr.a_match_value) )
        AND
        ( (cr.b_match_type='product_brand'      AND o.brand = cr.b_match_value) OR
          (cr.b_match_type='brand_owner'        AND o.owner = cr.b_match_value) OR
          (cr.b_match_type='name'               AND o.nm    = cr.b_match_value) OR
          (cr.b_match_type='family_id'  AND o.fam IS NOT NULL AND o.fam::text = cr.b_match_value) )
    )
    OR
    EXISTS (
      SELECT 1 FROM cand c
      JOIN public.coexistence_rules cr ON cr.scope='machine' AND cr.rule_type='hard' AND cr.is_active
      JOIN onm o ON
        ( (cr.b_match_type='product_brand'      AND c.brand = cr.b_match_value) OR
          (cr.b_match_type='brand_owner'        AND c.owner = cr.b_match_value) OR
          (cr.b_match_type='name'               AND c.nm    = cr.b_match_value) OR
          (cr.b_match_type='family_id'  AND c.fam IS NOT NULL AND c.fam::text = cr.b_match_value) )
        AND
        ( (cr.a_match_type='product_brand'      AND o.brand = cr.a_match_value) OR
          (cr.a_match_type='brand_owner'        AND o.owner = cr.a_match_value) OR
          (cr.a_match_type='name'               AND o.nm    = cr.a_match_value) OR
          (cr.a_match_type='family_id'  AND o.fam IS NOT NULL AND o.fam::text = cr.a_match_value) )
    );
$function$;

-- 5. Rule-2 NARROW flip: deactivate the same-brand max-1 rows (groups 2/3/4/7); add their family_id equivalents.
--    Groups 1/5/6 (cross-brand exclusions) are untouched.
UPDATE public.coexistence_rules SET is_active=false
 WHERE rule_group IN ('group2_coca_cola','group3_pepsi','group4_almarai_juice','group7_loacker')
   AND a_match_type='product_brand' AND b_match_type='product_brand';

-- Emit a family_id rule for EVERY PAIR of curated families a brand group occupies (incl. same-family and
-- cross-sub-family), so "max-1 across the whole brand" is preserved (the curated taxonomy is finer than
-- brands). Co-family leak = 0 (verified), so each group's family-set contains only that brand's products.
WITH grp_fam AS (
  SELECT g.rule_group, bp.product_family_id AS fid
  FROM (VALUES
     ('group2_coca_cola','Coca Cola'),
     ('group3_pepsi','Pepsi'),
     ('group4_almarai_juice','Almarai Juice'),
     ('group7_loacker','Loacker'),
     ('group7_loacker','Loackers Quadratini')
  ) g(rule_group, brand)
  JOIN public.boonz_products bp ON bp.product_brand = g.brand AND bp.product_family_id IS NOT NULL
  GROUP BY g.rule_group, bp.product_family_id
)
INSERT INTO public.coexistence_rules (rule_group, a_match_type, a_match_value, b_match_type, b_match_value, scope, rule_type, note, is_active)
SELECT a.rule_group, 'family_id', a.fid::text, 'family_id', b.fid::text, 'machine', 'hard',
       'PRD-040 B2 narrow flip: max-1-per-brand via all-family-pairs (superseded brand proxy)', true
FROM grp_fam a JOIN grp_fam b ON a.rule_group = b.rule_group
ON CONFLICT DO NOTHING;

COMMENT ON COLUMN public.coexistence_rules.is_active IS
  'PRD-040 B2: false = superseded rule (kept for audit, not enforced). _coexistence_blocks filters is_active.';
