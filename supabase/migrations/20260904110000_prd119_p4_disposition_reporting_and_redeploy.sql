-- PRD-119 P4: read-only reporting objects over disposition_events, plus the
-- missing redeploy_pending -> redeployed writer.
--
-- v_disposition_ledger: base ledger read view, names joined, is_current flag
-- (superseded_by_event IS NULL). Canonical object for the admin ledger screen
-- and all waste/redeploy reports -- no FE re-derivation of these joins.
--
-- v_redeploy_outcomes: canonical object for the "redeploy success rate"
-- metric -- one self-join following the append-only supersede chain one hop
-- (redeploy_pending has exactly one possible successor state today:
-- redeployed), so callers don't hand-walk the chain themselves.
--
-- v_waste_by_sku_90d: canonical object for the procurement weekly-demand
-- hook (waste qty/value per SKU, last 90 days) -- joins on boonz_product_id
-- against get_procurement_demand's existing row shape without touching that
-- RPC.
--
-- confirm_disposition_redeploy: wm_confirm_line's redeploy_pending path had
-- no closing writer -- nothing ever advanced a redeploy_pending row to
-- redeployed. New DEFINER RPC, same append-only chain pattern already
-- shipped and Cody-approved for wm_confirm_line this session: INSERT the new
-- 'redeployed' row, then UPDATE only the prior row's superseded_by_event
-- pointer (never its state) -- done by the DEFINER as table owner, the
-- authenticated-role REVOKE from P1's disposition_events migration is
-- untouched. Deliberately does NOT touch warehouse_inventory -- the stock
-- movement for a redeploy is the normal dispatch/pick pipeline's job
-- (Article 6/pick_wh_batch_for_machine territory); this RPC is bookkeeping
-- confirmation only, once a WM has observed the item actually arrive.
--
-- Verified live in a rolled-back transaction: dry-run + real call on a
-- synthetic redeploy_pending fixture correctly produced a new 'redeployed'
-- row (superseded_by_event NULL) while the original row kept its state and
-- gained a superseded_by_event pointer to the new row.
--
-- Cody: approve, Articles 1/4/6/7/16.
CREATE OR REPLACE VIEW public.v_disposition_ledger AS
SELECT
  e.event_id, e.created_at, e.actor, up.full_name AS actor_name, e.source,
  e.machine_id, m1.official_name AS machine_name,
  e.shelf_id, e.boonz_product_id, bp.boonz_product_name, bp.sourcing_channel,
  e.expiration_date, e.qty, e.state, e.disposal_code,
  e.target_machine_id, m2.official_name AS target_machine_name,
  e.waste_by, e.value_aed, e.reason, e.dispatch_id, e.wh_inventory_id, e.pod_inventory_id,
  e.superseded_by_event, (e.superseded_by_event IS NULL) AS is_current
FROM public.disposition_events e
LEFT JOIN public.user_profiles up ON up.id = e.actor
LEFT JOIN public.machines m1 ON m1.machine_id = e.machine_id
LEFT JOIN public.machines m2 ON m2.machine_id = e.target_machine_id
LEFT JOIN public.boonz_products bp ON bp.product_id = e.boonz_product_id;

CREATE OR REPLACE VIEW public.v_redeploy_outcomes AS
SELECT
  e.event_id AS redeploy_event_id, e.boonz_product_id, bp.boonz_product_name,
  e.target_machine_id, m.official_name AS target_machine_name,
  e.qty, e.value_aed, e.created_at AS proposed_at,
  s.state AS outcome_state, s.created_at AS resolved_at, s.event_id AS outcome_event_id
FROM public.disposition_events e
LEFT JOIN public.disposition_events s ON s.event_id = e.superseded_by_event
LEFT JOIN public.boonz_products bp ON bp.product_id = e.boonz_product_id
LEFT JOIN public.machines m ON m.machine_id = e.target_machine_id
WHERE e.state = 'redeploy_pending';

CREATE OR REPLACE VIEW public.v_waste_by_sku_90d AS
SELECT boonz_product_id, sum(qty) AS waste_qty_90d, sum(value_aed) AS waste_value_90d, count(*) AS waste_events_90d
FROM public.disposition_events
WHERE state = 'waste' AND created_at >= now() - interval '90 days'
GROUP BY boonz_product_id;

CREATE OR REPLACE FUNCTION public.confirm_disposition_redeploy(
  p_event_id uuid,
  p_caller uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_ev record;
  v_new_event_id uuid;
BEGIN
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN RAISE EXCEPTION 'forbidden: confirm_disposition_redeploy requires warehouse, operator_admin, superadmin, or manager'; END IF;

  IF p_event_id IS NULL THEN RAISE EXCEPTION 'confirm_disposition_redeploy: p_event_id is required'; END IF;

  SELECT * INTO v_ev FROM public.disposition_events
   WHERE event_id = p_event_id AND state = 'redeploy_pending' AND superseded_by_event IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'confirm_disposition_redeploy: % is not an open redeploy_pending event', p_event_id; END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run_ok','event_id',p_event_id,'target_machine_id',v_ev.target_machine_id,
      'boonz_product_id', v_ev.boonz_product_id, 'qty', v_ev.qty, 'expiration_date', v_ev.expiration_date);
  END IF;

  PERFORM public.set_write_context('confirm_disposition_redeploy',
    format('confirm_disposition_redeploy event=%s target_machine=%s qty=%s by=%s',
      p_event_id, v_ev.target_machine_id, v_ev.qty, COALESCE(v_user_id::text,'system')),
    'dispatch_return', p_event_id::text);

  INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state,
     target_machine_id, value_aed, reason, dispatch_id, wh_inventory_id)
  VALUES (v_user_id, v_ev.source, v_ev.target_machine_id, NULL, v_ev.boonz_product_id, v_ev.expiration_date, v_ev.qty, 'redeployed',
     v_ev.target_machine_id, v_ev.value_aed, concat('redeploy confirmed from event ', p_event_id), v_ev.dispatch_id, v_ev.wh_inventory_id)
  RETURNING event_id INTO v_new_event_id;

  UPDATE public.disposition_events SET superseded_by_event = v_new_event_id WHERE event_id = p_event_id;

  RETURN jsonb_build_object('status','confirmed','event_id',p_event_id,'new_event_id',v_new_event_id,
    'target_machine_id', v_ev.target_machine_id, 'qty', v_ev.qty);
END $function$;
