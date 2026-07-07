-- PRD-081 (Cody PASS, revisions applied): pack-rpc-only guard, shipped WARN.
-- Enforces (Article 1/3) that refill_dispatching pack-state flips only via a sanctioned pack
-- RPC. WARN = log bypasses non-blocking; ENFORCE = raise. Reversible (pack_guard=off/drop). Family A untouched.
CREATE TABLE IF NOT EXISTS public.refill_pack_bypass_log (
  bypass_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), dispatch_id uuid NOT NULL, rpc_name text,
  via_rpc boolean NOT NULL DEFAULT false, changed_at timestamptz NOT NULL DEFAULT now(), detail jsonb NOT NULL);
ALTER TABLE public.refill_pack_bypass_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rpbl_select ON public.refill_pack_bypass_log;
DROP POLICY IF EXISTS rpbl_no_update ON public.refill_pack_bypass_log;
DROP POLICY IF EXISTS rpbl_no_delete ON public.refill_pack_bypass_log;
CREATE POLICY rpbl_select ON public.refill_pack_bypass_log FOR SELECT TO authenticated USING (true);
CREATE POLICY rpbl_no_update ON public.refill_pack_bypass_log FOR UPDATE USING (false);
CREATE POLICY rpbl_no_delete ON public.refill_pack_bypass_log FOR DELETE USING (false);
CREATE INDEX IF NOT EXISTS idx_rpbl_changed ON public.refill_pack_bypass_log (changed_at DESC);
CREATE OR REPLACE FUNCTION public.tg_enforce_pack_via_rpc() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_rpc text := NULLIF(current_setting('app.rpc_name', true),''); v_via text := current_setting('app.via_rpc', true); v_mode text := refill_qa.flag('pack_guard');
BEGIN
  IF v_via IS DISTINCT FROM 'true' OR v_rpc IS NULL OR v_rpc NOT IN ('pack_dispatch_line','confirm_packed_transferred') THEN
    IF v_mode = 'enforce' THEN
      RAISE EXCEPTION 'refill_dispatching pack-state may change only via a sanctioned pack RPC (pack_guard=enforce). saw rpc=%, via_rpc=%', COALESCE(v_rpc,'(none)'), COALESCE(v_via,'(none)');
    ELSE
      INSERT INTO public.refill_pack_bypass_log(dispatch_id, rpc_name, via_rpc, detail)
      VALUES (NEW.dispatch_id, v_rpc, v_via IS NOT DISTINCT FROM 'true', jsonb_build_object('mode',COALESCE(v_mode,'warn'),'machine_id',NEW.machine_id,'filled',NEW.filled_quantity));
    END IF;
  END IF;
  RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS trg_enforce_pack_via_rpc ON public.refill_dispatching;
CREATE TRIGGER trg_enforce_pack_via_rpc BEFORE UPDATE ON public.refill_dispatching
  FOR EACH ROW WHEN (NEW.packed = true AND OLD.packed IS DISTINCT FROM true)
  EXECUTE FUNCTION public.tg_enforce_pack_via_rpc();
INSERT INTO refill_qa.feature_flag(flag,value) VALUES ('pack_guard','warn') ON CONFLICT (flag) DO NOTHING;
