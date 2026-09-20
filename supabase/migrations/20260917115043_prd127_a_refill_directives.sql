-- PRD-127 Block A: refill_directives, a durable table for CS to steer
-- propose_refill_plan / a future conversational layer without a one-off SQL
-- edit each time ("never recommend this product again"). Only directive_type
-- = 'block' is implemented -- widen the CHECK the day a second type is
-- actually needed, per this session's own no-speculative-features rule.

CREATE TABLE IF NOT EXISTS public.refill_directives (
  directive_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  directive_type text NOT NULL CHECK (directive_type = 'block'),
  target_kind    text NOT NULL CHECK (target_kind IN ('machine','pod_product','boonz_product')),
  target_id      uuid NOT NULL,
  target_name    text NOT NULL,
  note           text NOT NULL CHECK (length(btrim(note)) >= 10),
  active         boolean NOT NULL DEFAULT true,
  created_by     uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at     timestamptz NOT NULL DEFAULT now(),
  retired_by     uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  retired_at     timestamptz,
  retired_reason text
);

CREATE INDEX IF NOT EXISTS idx_refill_directives_active_target
  ON public.refill_directives (target_kind, target_id) WHERE active;
-- Serves propose_refill_plan's per-lane lookup: "is there an active block on
-- this machine_id / pod_product_id / boonz_product_id".

ALTER TABLE public.refill_directives ENABLE ROW LEVEL SECURITY;

CREATE POLICY refill_directives_select ON public.refill_directives
  FOR SELECT TO authenticated USING (true);
-- S-308: authenticated is born with INSERT/UPDATE/DELETE too -- explicitly
-- revoke them; the two RPCs below are the only canonical writers (Article 1).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.refill_directives FROM authenticated;
REVOKE ALL ON public.refill_directives FROM anon, PUBLIC;
GRANT SELECT ON public.refill_directives TO authenticated;

CREATE OR REPLACE FUNCTION public._resolve_refill_directive_target(p_target text)
RETURNS TABLE(target_kind text, target_id uuid, target_name text)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT 'machine', m.machine_id, m.official_name
    FROM public.machines m
   WHERE lower(btrim(m.official_name)) = lower(btrim(p_target))
  UNION ALL
  SELECT 'pod_product', pp.pod_product_id, pp.pod_product_name
    FROM public.pod_products pp
   WHERE lower(btrim(pp.pod_product_name)) = lower(btrim(p_target))
  UNION ALL
  SELECT 'boonz_product', bp.product_id, bp.boonz_product_name
    FROM public.boonz_products bp
   WHERE lower(btrim(bp.boonz_product_name)) = lower(btrim(p_target));
$function$;

CREATE OR REPLACE FUNCTION public.add_refill_directive(
  p_directive_type text,
  p_target text,
  p_note text,
  p_caller uuid DEFAULT auth.uid()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_role    text;
  v_matches int;
  v_kind    text;
  v_id      uuid;
  v_name    text;
  v_directive_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'add_refill_directive', true);

  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'add_refill_directive: forbidden for role % (operator_admin, superadmin or manager required)',
        COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  IF p_directive_type IS NULL OR btrim(p_directive_type) <> 'block' THEN
    RAISE EXCEPTION 'add_refill_directive: p_directive_type must be ''block'' (got %)', p_directive_type;
  END IF;
  IF p_target IS NULL OR btrim(p_target) = '' THEN
    RAISE EXCEPTION 'add_refill_directive: p_target is required';
  END IF;
  IF p_note IS NULL OR length(btrim(p_note)) < 10 THEN
    RAISE EXCEPTION 'add_refill_directive: p_note is required (>=10 chars)';
  END IF;

  SELECT count(*) INTO v_matches FROM public._resolve_refill_directive_target(p_target);
  IF v_matches = 0 THEN
    RAISE EXCEPTION 'add_refill_directive: % matches nothing in machines, pod_products, or boonz_products -- refusing to guess',
      p_target;
  ELSIF v_matches > 1 THEN
    RAISE EXCEPTION 'add_refill_directive: % is ambiguous (% matches across machines/pod_products/boonz_products: %) -- refusing to guess',
      p_target, v_matches,
      (SELECT string_agg(format('%s:%s', r.target_kind, r.target_name), ', ')
         FROM public._resolve_refill_directive_target(p_target) r);
  END IF;

  SELECT r.target_kind, r.target_id, r.target_name
    INTO v_kind, v_id, v_name
    FROM public._resolve_refill_directive_target(p_target) r;

  INSERT INTO public.refill_directives
    (directive_type, target_kind, target_id, target_name, note, created_by)
  VALUES
    (p_directive_type, v_kind, v_id, v_name, p_note, v_user_id)
  RETURNING directive_id INTO v_directive_id;

  RETURN v_directive_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.retire_refill_directive(
  p_directive_id uuid,
  p_reason text,
  p_caller uuid DEFAULT auth.uid()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_role    text;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'retire_refill_directive', true);

  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'retire_refill_directive: forbidden for role % (operator_admin, superadmin or manager required)',
        COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  IF p_directive_id IS NULL THEN
    RAISE EXCEPTION 'retire_refill_directive: p_directive_id is required';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'retire_refill_directive: p_reason is required (>=10 chars)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.refill_directives WHERE directive_id = p_directive_id AND active) THEN
    RAISE EXCEPTION 'retire_refill_directive: % not found or already retired', p_directive_id;
  END IF;

  UPDATE public.refill_directives
     SET active = false, retired_by = v_user_id, retired_at = now(), retired_reason = p_reason
   WHERE directive_id = p_directive_id;
END;
$function$;

REVOKE ALL ON FUNCTION public._resolve_refill_directive_target(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._resolve_refill_directive_target(text) TO authenticated;
REVOKE ALL ON FUNCTION public.add_refill_directive(text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_refill_directive(text, text, text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.retire_refill_directive(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.retire_refill_directive(uuid, text, uuid) TO authenticated;

-- Seed: BLOCK on Oreo Cookie - Regular, per the goal prompt's own explicit
-- instruction and created_by id.
SELECT public.add_refill_directive(
  'block',
  'Oreo Cookie - Regular',
  'out of stock in the UAE',
  '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid
);
