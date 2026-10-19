-- Rollback for PRD-144 P2-1 (reintro intents). Removes the engine_add_pod key, the proposals RPC, the
-- reintro rows and columns, and restores the original intent CHECK.
DO $patch$
DECLARE v_def text; n int;
  a_new text := '    ''sizing_mode'', v_mode,' || chr(10) || '    ''reintro_proposals'', public.get_reintro_proposals(p_plan_date, NULL::uuid[]),  -- PRD-144 P2-1' || chr(10);
BEGIN
  v_def := pg_get_functiondef('public.engine_add_pod(date,integer)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, a_new, ''))) / length(a_new);
  IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_1 rollback: engine_add_pod anchor count %', n; END IF;
  EXECUTE replace(v_def, a_new, '    ''sizing_mode'', v_mode,' || chr(10));
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.engine_add_pod(date, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_add_pod(date, integer) TO authenticated, service_role;
DROP FUNCTION IF EXISTS public.get_reintro_proposals(date, uuid[]);
DELETE FROM public.sku_intents WHERE intent = 'reintro_when_stocked';
ALTER TABLE public.sku_intents DROP CONSTRAINT IF EXISTS sku_intents_preferred_lane_size_check;
ALTER TABLE public.sku_intents DROP CONSTRAINT IF EXISTS sku_intents_reintro_shape_check;
ALTER TABLE public.sku_intents DROP COLUMN IF EXISTS preferred_lane_size;
ALTER TABLE public.sku_intents DROP COLUMN IF EXISTS min_wh_stock;
ALTER TABLE public.sku_intents DROP CONSTRAINT sku_intents_intent_check;
ALTER TABLE public.sku_intents ADD CONSTRAINT sku_intents_intent_check
  CHECK (intent = ANY (ARRAY['deplete'::text, 'temp_out'::text, 'keep'::text, 'push'::text]));
