-- PRD-110 P3.1c — golden fixture 44: stitch_v3 skeleton
-- plan_date 2030-02-14 (golden.render: DATE '2030-01-01' + fixture_id).
-- LAW 1: this fixture reds without the two migrations that precede it.

DELETE FROM golden.assertions WHERE fixture_id = 44;
DELETE FROM golden.fixtures   WHERE fixture_id = 44;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
44,
'stitch_v3 drives every planned pod line through the supply ladder, rewrites the pod on a substitution while preserving the anchor, and carries every unplaceable unit in an explicit Blocked row so a partial fill can never become a silent qty-0 (P3.1c)',
'PRD-110 leg 63 raised S-86 and S-87 as written contracts BEFORE stitch_v3 existed. S-86: the ladder does not cascade after a partial fill, so a terminal rung may serve less than was asked and the stranded remainder is the CONSUMER''s LAW 5 obligation - fixture 40 seq 55 states it, this fixture enforces it. S-87: resolve_m2m_sku_legs_v3 with p_lines=NULL is inert on this fleet (shelf_composition covers 16 of 656 shelves), so a rung-4 termination that defaults p_lines strands units silently.',
'P3',
DATE '2030-02-14',
true,
'failing_expected',
'P3.1c SKELETON. Anchors: P = MPMCC-1058 A02 Red Bull asked at net_primary + 1, so the rung-1 PARTIAL is guaranteed BY CONSTRUCTION and cannot rot into a vacuous pass as live warehouse stock moves (fixture 40 anchor D''s idiom). F = Fade Fit on 148c4fcf, an ORDINARY fully-satisfied line that terminates at rung 2 - included deliberately per S-85, because a suite built only from starved anchors never executes the happy path and reads green over a blind spot. F also proves the anchor/resolved pod split: a substitution rewrites pod_product_id while anchor_pod_product_id still records what was asked. The scenario INSERTs a fresh source run into pod_refills_shadow on every execution (fresh run_id) because that table is append-only by trigger and its qty must be recomputed each run to keep the net+1 guarantee live; rows therefore accumulate ~2 per run, which is the ledger semantics ADR-shadow-plan-tables sec 5.4 bounds at 90 days. NOT YET COVERED: the rung-4 m2m branch is SQL-validated standalone but no live line terminates at rung 4, so it has never executed end-to-end - see seq 22, which pins the S-87 contract on whatever does reach it.',
$scen$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (1) SUPPLY EVIDENCE, derived straight from base tables and INDEPENDENTLY of
--     the function under test, so the assertions below never ask stitch_v3 to
--     confirm its own arithmetic.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH anchors(tag, machine_id, shelf_id, pod_product_id) AS (
  VALUES ('P', '9acce2bf-0e65-48f4-bf44-cefa0326f2c5'::uuid,
               '65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid,
               'a602c923-c4c0-4ecc-b5f7-3c13a1960beb'::uuid),
         ('F', '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,
               '48907909-7b0c-438b-8183-95ceaf1b4b81'::uuid,
               '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid)
),
-- product_mapping fan-out guard (S-67): DISTINCT the variants BEFORE summing stock.
variants AS (
  SELECT a.tag, a.machine_id, v.boonz_product_id
  FROM anchors a
  CROSS JOIN LATERAL (
    SELECT DISTINCT pm.boonz_product_id
    FROM public.product_mapping pm
    WHERE pm.pod_product_id = a.pod_product_id
      AND pm.status = 'Active'
      AND (pm.machine_id = a.machine_id OR pm.machine_id IS NULL)
  ) v
),
claims AS (
  SELECT a.tag, COALESCE(SUM(pr.qty), 0)::int AS claimed
  FROM anchors a
  LEFT JOIN public.pod_refills pr
         ON pr.plan_date = {{plan_date}}
        AND pr.pod_product_id = a.pod_product_id
        AND pr.shelf_id IS DISTINCT FROM a.shelf_id
  GROUP BY a.tag
),
supply AS (
  SELECT vr.tag,
         COALESCE(SUM(w.warehouse_stock) FILTER (
            WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
              AND w.warehouse_id = mc.primary_warehouse_id), 0) AS real_primary,
         COALESCE(SUM(w.warehouse_stock) FILTER (
            WHERE w.batch_id LIKE 'VOXSOURCE-%'), 0)            AS sentinel_units
  FROM variants vr
  JOIN public.machines mc ON mc.machine_id = vr.machine_id
  LEFT JOIN public.v_wh_pickable w
         ON w.boonz_product_id = vr.boonz_product_id
        AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = vr.machine_id)
  GROUP BY vr.tag
)
SELECT {{fixture_id}}, 'supply', jsonb_build_object(
  'P_real_primary', (SELECT real_primary   FROM supply WHERE tag='P'),
  'P_sentinel',     (SELECT sentinel_units FROM supply WHERE tag='P'),
  'P_claimed',      (SELECT claimed        FROM claims WHERE tag='P'),
  'P_net_primary',  GREATEST((SELECT real_primary FROM supply WHERE tag='P')
                             - (SELECT claimed FROM claims WHERE tag='P'), 0),
  -- ⭐ net + 1: the partial is STRUCTURAL, not a snapshot of today's stock.
  'P_need',         GREATEST((SELECT real_primary FROM supply WHERE tag='P')
                             - (SELECT claimed FROM claims WHERE tag='P'), 0) + 1,
  'F_real_primary', (SELECT real_primary   FROM supply WHERE tag='F'),
  'F_sentinel',     (SELECT sentinel_units FROM supply WHERE tag='F'),
  'F_need',         5
);

-- ---------------------------------------------------------------------------
-- (2) A FRESH source run. pod_refills_shadow is append-only by trigger, so the
--     run cannot be rewritten in place; a new run_id per execution is what keeps
--     P's qty recomputed and the net+1 guarantee alive.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'src_run', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT ((SELECT value FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key='src_run') #>> '{}')::uuid,
       'engine_add_pod_v3', {{plan_date}}, a.mid, a.sid, a.pid, a.qty, 'boonz_wh', 0
FROM (VALUES
  ('9acce2bf-0e65-48f4-bf44-cefa0326f2c5'::uuid,'65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid,
   'a602c923-c4c0-4ecc-b5f7-3c13a1960beb'::uuid,
   (SELECT (value->>'P_need')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key='supply')),
  ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'48907909-7b0c-438b-8183-95ceaf1b4b81'::uuid,
   '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid, 5)
) AS a(mid,sid,pid,qty);

-- ---------------------------------------------------------------------------
-- (3) THE FUNCTION UNDER TEST. to_regprocedure-guarded so the RED baseline still
--     completes and every population fact above lands in scratch: the RED then
--     isolates exactly the object being built (fixture 40's idiom).
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public.stitch_v3(date,uuid)') IS NOT NULL THEN
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 44, 'stitch', public.stitch_v3(
        DATE '2030-02-14',
        ((SELECT value FROM golden.scratch WHERE fixture_id = 44 AND key='src_run') #>> '{}')::uuid)
    $x$;
  END IF;
END
$do$;
$scen$
);

-- ---------------------------------------------------------------------------
-- ASSERTIONS. BARE INSERTs (S-78).
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

(44, 1, 'Drift guard: {{plan_date}} still renders as the fixture-44 anchor 2030-02-14',
 'SELECT {{plan_date}}::text', 'eq', '2030-02-14', true, 'P3'),

(44, 2, 'Anchor guard (P): Red Bull a602c923 is still categorised Energy & Sports Drinks',
 'SELECT pp.product_category FROM public.pod_products pp WHERE pp.pod_product_id = ''a602c923-c4c0-4ecc-b5f7-3c13a1960beb''::uuid',
 'eq', 'Energy & Sports Drinks', true, 'P3'),

(44, 3, 'Anchor guard (P): machine MPMCC-1058 9acce2bf is still co_managed with a primary warehouse',
 'SELECT m.operating_model || ''|'' || (m.primary_warehouse_id IS NOT NULL)::text FROM public.machines m WHERE m.machine_id = ''9acce2bf-0e65-48f4-bf44-cefa0326f2c5''::uuid',
 'eq', 'co_managed|true', true, 'P3'),

(44, 4, 'Anchor guard (F): Fade Fit 733dcd39 is still categorised Protein & Health Bars',
 'SELECT pp.product_category FROM public.pod_products pp WHERE pp.pod_product_id = ''733dcd39-dd50-4446-b1e4-5b36afbdf72a''::uuid',
 'eq', 'Protein & Health Bars', true, 'P3'),

(44, 5, 'NON-VACUITY (P): rung 1 is satisfiable at all (net primary >= 1), so P is a genuine rung-1 PARTIAL and not a disguised rung-2 case. If this reds, re-pick anchor P - do NOT weaken seq 15',
 'SELECT (value->>''P_net_primary'')::int FROM golden.scratch WHERE fixture_id = 44 AND key = ''supply''',
 'gte', '1', true, 'P3'),

(44, 6, 'NON-VACUITY (P): the ask is exactly one unit MORE than rung 1 can serve, so the shortfall is structural',
 'SELECT ((value->>''P_need'')::int - (value->>''P_net_primary'')::int) FROM golden.scratch WHERE fixture_id = 44 AND key = ''supply''',
 'eq', '1', true, 'P3'),

(44, 7, 'The scenario seeded exactly 2 source lines into pod_refills_shadow for this run',
 'SELECT count(*)::int FROM public.pod_refills_shadow s WHERE s.run_id = ((SELECT value FROM golden.scratch WHERE fixture_id = 44 AND key=''src_run'') #>> ''{}'')::uuid',
 'eq', '2', true, 'P3'),

(44, 8, 'S-62 SENSOR: stitch_v3(date,uuid) EXISTS. This is the assertion the whole fixture reds on before P3.1c lands',
 'SELECT (to_regprocedure(''public.stitch_v3(date,uuid)'') IS NOT NULL)::text', 'eq', 'true', true, 'P3'),

(44, 9, 'S-85 REGRESSION SENSOR: stitch_v3 RETURNED an object. A function that raises leaves no scratch key at all, so this catches the whole crash class',
 'SELECT count(*)::int FROM golden.scratch WHERE fixture_id = 44 AND key = ''stitch'' AND jsonb_typeof(value) = ''object''',
 'eq', '1', true, 'P3'),

(44, 10, 'stitch_v3 reports status ok',
 'SELECT value->>''status'' FROM golden.scratch WHERE fixture_id = 44 AND key = ''stitch''',
 'eq', 'ok', true, 'P3'),

(44, 11, 'stitch_v3 consumed both source lines - neither was silently skipped',
 'SELECT value->>''lines_in'' FROM golden.scratch WHERE fixture_id = 44 AND key = ''stitch''',
 'eq', '2', true, 'P3'),

(44, 12, 'LAW 5 / CONSERVATION (reported): units_placed + units_blocked = units_in, exactly',
 'SELECT (((value->>''units_placed'')::int + (value->>''units_blocked'')::int) = (value->>''units_in'')::int)::text FROM golden.scratch WHERE fixture_id = 44 AND key = ''stitch''',
 'eq', 'true', true, 'P3'),

(44, 13, 'LAW 5 / CONSERVATION (measured on the rows, not the summary): for EVERY source line, the emitted quantities sum to exactly what was asked. Counts the violations, so it cannot pass vacuously',
 'SELECT count(*)::int FROM (SELECT s.shelf_id, s.qty, COALESCE(SUM(o.qty),0)::int AS emitted FROM public.pod_refills_shadow s LEFT JOIN public.refill_plan_output_shadow o ON o.source_run_id = s.run_id AND o.shelf_id = s.shelf_id AND o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid WHERE s.run_id = ((SELECT value FROM golden.scratch WHERE fixture_id = 44 AND key=''src_run'') #>> ''{}'')::uuid GROUP BY s.shelf_id, s.qty) x WHERE x.emitted <> x.qty',
 'eq', '0', true, 'P3'),

(44, 14, 'LAW 5: every source line produced at least one output row. A line that vanished entirely IS the silent qty-0 this fixture exists to forbid',
 'SELECT count(*)::int FROM public.pod_refills_shadow s WHERE s.run_id = ((SELECT value FROM golden.scratch WHERE fixture_id = 44 AND key=''src_run'') #>> ''{}'')::uuid AND NOT EXISTS (SELECT 1 FROM public.refill_plan_output_shadow o WHERE o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid AND o.shelf_id = s.shelf_id)',
 'eq', '0', true, 'P3'),

(44, 15, 'S-86 CONTRACT (P): the partial produced BOTH a placeable row and a Blocked row on the same shelf',
 'SELECT (count(*) FILTER (WHERE action <> ''Blocked'') > 0 AND count(*) FILTER (WHERE action = ''Blocked'') > 0)::text FROM public.refill_plan_output_shadow o WHERE o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid AND o.shelf_id = ''65d699ab-441c-43e7-9a5d-bbd90d0da08e''::uuid',
 'eq', 'true', true, 'P3'),

(44, 16, 'S-86 CONTRACT (P): the Blocked row carries exactly the one unit the ladder could not serve',
 'SELECT COALESCE(SUM(o.qty),0)::int FROM public.refill_plan_output_shadow o WHERE o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid AND o.shelf_id = ''65d699ab-441c-43e7-9a5d-bbd90d0da08e''::uuid AND o.action = ''Blocked''',
 'eq', '1', true, 'P3'),

(44, 17, 'S-86 CONTRACT (P), THE POINT OF THE WHOLE FIXTURE: the Blocked row''s terminal rung is variant#1, NOT blocked_demand#6. A shortfall does NOT mean the ladder reached rung 6, and any consumer that assumes it does is wrong',
 'SELECT o.resolved_rung || ''#'' || o.rung_no FROM public.refill_plan_output_shadow o WHERE o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid AND o.shelf_id = ''65d699ab-441c-43e7-9a5d-bbd90d0da08e''::uuid AND o.action = ''Blocked''',
 'eq', 'variant#1', true, 'P3'),

(44, 18, 'S-86 CONTRACT (P): the Blocked row names WHY, so procurement can act on it rather than guess',
 'SELECT o.reasoning->>''reason'' FROM public.refill_plan_output_shadow o WHERE o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid AND o.shelf_id = ''65d699ab-441c-43e7-9a5d-bbd90d0da08e''::uuid AND o.action = ''Blocked''',
 'eq', 'partial_wh_limited', true, 'P3'),

(44, 19, 'ORDINARY CASE (F), the S-85 lesson: the fully-satisfied line emitted NO Blocked row. A suite of only-starved anchors never proves this',
 'SELECT count(*)::int FROM public.refill_plan_output_shadow o WHERE o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid AND o.shelf_id = ''48907909-7b0c-438b-8183-95ceaf1b4b81''::uuid AND o.action = ''Blocked''',
 'eq', '0', true, 'P3'),

(44, 20, 'SUBSTITUTION (F): the resolved pod differs from the anchor pod, and the anchor still records what was ASKED. A substitution that overwrote the anchor would erase the demand signal',
 'SELECT (o.pod_product_id <> o.anchor_pod_product_id AND o.anchor_pod_product_id = ''733dcd39-dd50-4446-b1e4-5b36afbdf72a''::uuid)::text FROM public.refill_plan_output_shadow o WHERE o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid AND o.shelf_id = ''48907909-7b0c-438b-8183-95ceaf1b4b81''::uuid AND o.action = ''Add New''',
 'eq', 'true', true, 'P3'),

(44, 21, 'Every emitted row records the rung that produced it - an unexplained line is not auditable',
 'SELECT count(*)::int FROM public.refill_plan_output_shadow o WHERE o.run_id = ((SELECT value->>''run_id'' FROM golden.scratch WHERE fixture_id = 44 AND key=''stitch''))::uuid AND (o.resolved_rung IS NULL OR o.rung_no IS NULL)',
 'eq', '0', true, 'P3'),

(44, 22, 'S-87 CONTRACT: no m2m row was emitted without a SKU. resolve_m2m_sku_legs_v3 with p_lines=NULL returns source_composition_unknown on this fleet (16 of 656 shelves covered), so a rung-4 leg lacking boonz_product_id means units were stranded silently',
 'SELECT count(*)::int FROM public.refill_plan_output_shadow o WHERE o.resolved_rung = ''m2m'' AND o.action <> ''Blocked'' AND o.boonz_product_id IS NULL',
 'eq', '0', true, 'P3'),

(44, 23, 'LAW 4 (SHADOW, DON''T SWITCH): stitch_v3 wrote nothing to the LIVE plan tables for this plan_date',
 'SELECT ((SELECT count(*) FROM public.pod_refill_plan WHERE plan_date = {{plan_date}}) + (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = {{plan_date}}))::int',
 'eq', '0', true, 'P3'),

(44, 24, 'ADR sec 5.1 append-only is enforced by a TRIGGER, not by RLS. RLS USING(false) does not bind the owner, service_role, or a SECURITY DEFINER body - which is exactly how stitch_v3 writes',
 'SELECT count(*)::int FROM pg_trigger WHERE tgrelid = ''public.refill_plan_output_shadow''::regclass AND NOT tgisinternal AND tgname = ''tg_refill_plan_output_shadow_append_only''',
 'eq', '1', true, 'P3'),

(44, 25, 'Article 1/3: authenticated holds NO INSERT grant on the shadow ledger - stitch_v3 is its only writer',
 'SELECT count(*)::int FROM information_schema.role_table_grants WHERE table_name = ''refill_plan_output_shadow'' AND grantee = ''authenticated'' AND privilege_type = ''INSERT''',
 'eq', '0', true, 'P3'),

(44, 26, 'Article 2: RLS is enabled on the shadow ledger',
 'SELECT relrowsecurity::text FROM pg_class WHERE oid = ''public.refill_plan_output_shadow''::regclass',
 'eq', 'true', true, 'P3'),

(44, 27, 'RISK 101: stitch_v3 was minted ONCE, not overloaded. A second signature would let callers bind the wrong body',
 'SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = ''public'' AND p.proname = ''stitch_v3''',
 'eq', '1', true, 'P3'),

(44, 28, 'The ladder itself is byte-untouched by this leg (LAW 3): resolve_supply_ladder_v3 still carries its post-S-85 body',
 'SELECT md5(prosrc) FROM pg_proc WHERE proname = ''resolve_supply_ladder_v3''',
 'eq', '920b32d09cb4582076da775a0f5123e3', true, 'P3'),

(44, 29, 'v1 stitch_pod_to_boonz is byte-untouched - P3.1c is a forward-only PORT, never an edit of the live stitch (LAW 3, Article 12)',
 'SELECT md5(prosrc) FROM pg_proc WHERE proname = ''stitch_pod_to_boonz''',
 'eq', '806340b294d3a9ce85473d7be8b35049', true, 'P3'),

(44, 30, 'S-88 SENSOR: authenticated holds no TRUNCATE on the shadow ledger. TRUNCATE is the one write that bypasses BOTH RLS and the FOR EACH ROW append-only trigger, so without this revoke the immutable ledger is erasable by any logged-in user',
 'SELECT count(*)::int FROM information_schema.role_table_grants WHERE table_name = ''refill_plan_output_shadow'' AND grantee = ''authenticated'' AND privilege_type = ''TRUNCATE''',
 'eq', '0', true, 'P3');
