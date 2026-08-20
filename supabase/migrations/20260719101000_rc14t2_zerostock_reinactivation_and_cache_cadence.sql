-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- RC-14 Tier 2: zero-stock reinactivation. propose_inactivate_on_zero_stock() is an AFTER
-- UPDATE trigger on warehouse_inventory that auto-confirms an Inactive proposal the moment
-- both warehouse_stock and consumer_stock hit zero from non-zero, scoped to the current
-- active-period (RC-14 Tier 2a comment in the live body: blocks only if a newer inactivation
-- proposal exists than the most recent reactivation, so a restock -> reactivate -> re-zero
-- cycle can re-fire). sweep_inactivate_stale_zero_stock() is the companion RPC/cron catch-up
-- sweep for rows the transition-only trigger missed (already Active + zero stock with no
-- pending proposal), writing a 'zero_stock_sweep' monitoring_alert when it finds any.
-- "cache_cadence" in this migration's name could NOT be confirmed against current state:
-- searched cron.job for *cache*/*refresh* -- the only cache-named job is refresh_app_cache
-- (every 5 min, unrelated to zerostock) and it shows no signs of having been retimed by this
-- migration. Flagging: if a cache-cadence change was part of the original migration, it is
-- not recoverable from current state and is NOT reconstructed here.

CREATE OR REPLACE FUNCTION public.propose_inactivate_on_zero_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_proposal_id uuid;
BEGIN
  -- Only fire when the row JUST went to zero stock from non-zero,
  -- and the row is still Active.
  IF NEW.status = 'Active'
     AND COALESCE(NEW.warehouse_stock, 0) = 0
     AND COALESCE(NEW.consumer_stock,  0) = 0
     AND (
       COALESCE(OLD.warehouse_stock, 0) > 0 OR
       COALESCE(OLD.consumer_stock,  0) > 0
     )
  THEN
    -- Idempotency guard, SCOPED TO THE CURRENT ACTIVE-PERIOD (RC-14 Tier 2a):
    -- block only if an inactivation proposal already exists that is NEWER than the
    -- most recent reactivation proposal for this row. This preserves same-cycle dedup
    -- while re-enabling inactivation after any restock -> reactivate -> re-zero cycle.
    IF NOT EXISTS (
      SELECT 1
      FROM public.warehouse_inventory_status_proposal p
      WHERE p.wh_inventory_id = NEW.wh_inventory_id
        AND p.status          IN ('pending', 'confirmed')
        AND p.proposer_name   = 'propose_inactivate_on_zero_stock'
        AND p.proposed_status = 'Inactive'
        AND p.proposed_at > COALESCE((
              SELECT max(r.proposed_at)
              FROM public.warehouse_inventory_status_proposal r
              WHERE r.wh_inventory_id = NEW.wh_inventory_id
                AND r.proposed_status = 'Active'
            ), '-infinity'::timestamptz)
    ) THEN
      -- Tag for audit trigger
      PERFORM set_config('app.via_rpc', 'true', true);
      PERFORM set_config('app.rpc_name', 'propose_inactivate_on_zero_stock', true);

      -- Insert the proposal as already confirmed (auto-confirm)
      INSERT INTO public.warehouse_inventory_status_proposal (
        wh_inventory_id,
        current_status,
        proposed_status,
        reason,
        proposer_kind,
        proposer_name,
        status,
        decided_at,
        decision_note
      ) VALUES (
        NEW.wh_inventory_id,
        NEW.status,
        'Inactive',
        'Both warehouse_stock and consumer_stock reached zero. Propose marking batch Inactive.',
        'trigger',
        'propose_inactivate_on_zero_stock',
        'confirmed',
        now(),
        'Auto-confirmed: zero-stock inactivation does not require manual approval'
      );

      -- Apply the status change directly via UPDATE.
      -- Safe from recursion: the re-fired trigger will see NEW.status = 'Inactive'
      -- and skip the IF block above.
      UPDATE public.warehouse_inventory
      SET status = 'Inactive'
      WHERE wh_inventory_id = NEW.wh_inventory_id;

    END IF;
  END IF;

  RETURN NULL;  -- AFTER trigger return value is ignored
END;
$function$;

DROP TRIGGER IF EXISTS tg_propose_inactivate_on_zero_stock ON public.warehouse_inventory;
CREATE TRIGGER tg_propose_inactivate_on_zero_stock
  AFTER UPDATE OF warehouse_stock, consumer_stock ON public.warehouse_inventory
  FOR EACH ROW
  WHEN (
    (OLD.status = 'Active')
    AND (COALESCE(NEW.warehouse_stock, 0) = 0)
    AND (COALESCE(NEW.consumer_stock, 0) = 0)
    AND (COALESCE(OLD.warehouse_stock, 0) > 0 OR COALESCE(OLD.consumer_stock, 0) > 0)
  )
  EXECUTE FUNCTION public.propose_inactivate_on_zero_stock();

CREATE OR REPLACE FUNCTION public.sweep_inactivate_stale_zero_stock(p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_swept int := 0;
  v_rows jsonb;
BEGIN
  -- Cron-context bypass (mirrors cron_phantom_pod_alert): authenticated callers must be
  -- manager-class; a null-uid pg_cron / service_role context proceeds. anon EXECUTE is
  -- revoked below so anon cannot reach this path.
  IF auth.uid() IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'sweep_inactivate_stale_zero_stock: role % not permitted', COALESCE(v_role,'(none)');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','sweep_inactivate_stale_zero_stock',true);

  WITH stale AS (
    SELECT wi.wh_inventory_id, wi.status AS current_status
    FROM public.warehouse_inventory wi
    WHERE wi.status = 'Active'
      AND COALESCE(wi.warehouse_stock,0) = 0
      AND COALESCE(wi.consumer_stock,0) = 0
      AND NOT EXISTS (
        SELECT 1 FROM public.warehouse_inventory_status_proposal p
        WHERE p.wh_inventory_id = wi.wh_inventory_id
          AND p.status = 'pending'
          AND p.proposed_status = 'Inactive'
      )
    FOR UPDATE OF wi
  ), ins AS (
    INSERT INTO public.warehouse_inventory_status_proposal (
      wh_inventory_id, current_status, proposed_status, reason,
      proposer_kind, proposer_name, status, decided_at, decision_note
    )
    SELECT s.wh_inventory_id, s.current_status, 'Inactive',
           COALESCE(p_reason, 'Stale zero-stock sweep: warehouse_stock and consumer_stock are zero but row stayed Active (missed by transition-only trigger). Propose Inactive.'),
           'rpc', 'sweep_inactivate_stale_zero_stock', 'confirmed', now(),
           'Auto-confirmed: zero-stock inactivation does not require manual approval'
    FROM stale s
    RETURNING wh_inventory_id
  ), upd AS (
    UPDATE public.warehouse_inventory wi
       SET status = 'Inactive'
      FROM ins
     WHERE wi.wh_inventory_id = ins.wh_inventory_id
    RETURNING wi.wh_inventory_id
  )
  SELECT count(*), COALESCE(jsonb_agg(wh_inventory_id),'[]'::jsonb)
    INTO v_swept, v_rows FROM upd;

  IF v_swept > 0 THEN
    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('zero_stock_sweep','warning', jsonb_build_object(
      'title', format('sweep_inactivate_stale_zero_stock: %s stale Active zero-stock rows inactivated', v_swept),
      'rows', v_rows, 'swept_at', now()));
  END IF;

  RETURN jsonb_build_object('status','ok','swept', v_swept, 'wh_inventory_ids', v_rows);
END; $function$;
