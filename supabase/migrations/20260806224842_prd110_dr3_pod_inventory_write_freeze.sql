-- PRD-110 DR-3 — pod_inventory PHYSICAL WRITE-FREEZE
-- Design for Cody review (LAW 3). Three named deliverables per the 2026-08-04 ruling:
--   revoke  +  write-guard  +  daily-delta report.   Ships FLAG-OFF.
--
-- MEASURED FACTS THIS DESIGN RESTS ON (all re-read live at leg 138, not remembered):
--  · pod_inventory: 9,528 rows · RLS on · policies authenticated_read_inventory_pod (SELECT)
--    and field_write_pod_inventory (ALL).
--  · Table grants today: authenticated AND service_role hold INSERT/UPDATE/DELETE/TRUNCATE;
--    anon holds only SELECT/REFERENCES/TRIGGER.
--  · Live triggers: tg_audit_pod_inventory · tg_warn_pod_inventory_null_expiry ·
--    trg_block_direct_pod_inventory_insert.
--    ⛔ THE LIVE GUARD IS **INSERT-ONLY**. UPDATE and DELETE are unguarded today. That gap is
--    the substance of the "write-guard" deliverable.
--  · 14 writer functions touch the table; ALL 14 are SECURITY DEFINER owned by `postgres`,
--    so REVOKEing from authenticated cannot reach them.
--  · All five FE call sites (products page, field page ×2, field/pod-inventory, AddProductDialog)
--    are `.select(...)` ONLY — verified by reading each one. Nothing in the FE writes this table.
--  · pod_inventory_audit_log: 15,077 rows, ~150-215 writes/day for the last 10 days. It already
--    carries operation/source/delta/actor — the daily-delta report needs no new capture.
--  · inventory_events holds 65 rows and shelf_composition 31. ⭐ The replacement is NOT yet
--    carrying the load, and the report is built to SAY so rather than to flatter the cutover.

-- APPLIED leg 140 as 20260806224842. ⚠️ lock_timeout added at apply time (NOT a semantic
-- change to Cody's reviewed design): the trigger DDL takes ACCESS EXCLUSIVE on pod_inventory,
-- and failing fast beats queueing in front of every other writer.
SET LOCAL lock_timeout = '5s';

-- ─────────────────────────────────────────────────────────────────────────────
-- (a) THE DIAL — four levels, ships 'off'
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS pod_inventory_write_freeze text NOT NULL DEFAULT 'off';

ALTER TABLE public.refill_policy_params
  DROP CONSTRAINT IF EXISTS chk_pod_inventory_write_freeze;
ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_pod_inventory_write_freeze
  CHECK (pod_inventory_write_freeze IN ('off','warn','block','frozen'));

-- LEVEL SEMANTICS, stated so no successor has to infer them:
--   'off'    inert. The guard returns immediately. THIS IS WHAT SHIPS (LAW 4 discipline).
--   'warn'   a non-RPC UPDATE/DELETE still succeeds but RAISEs a WARNING naming the verb.
--   'block'  a non-RPC UPDATE/DELETE is refused. Canonical RPCs still write.
--            ⭐ At 'block' the table is *writer-gated*, matching what INSERT has always been.
--   'frozen' EVERY UPDATE/DELETE is refused, RPCs included. ⭐ THIS is "read-only historical"
--            per BUILD SPEC P1.4 line 68, and it is the step that needs the 2-week delta
--            report plus a CS approve. It is NOT reachable by accident: three levels away.

-- ─────────────────────────────────────────────────────────────────────────────
-- (b) THE WRITE-GUARD — UPDATE and DELETE, the two verbs nothing guards today
-- ─────────────────────────────────────────────────────────────────────────────
-- ⛔ trg_block_direct_pod_inventory_insert is DELIBERATELY NOT TOUCHED. It is live, correct,
--    and unconditional; folding it into this dial would WEAKEN INSERT (it would become
--    bypassable at 'off'). Versioned addition only, no destructive change.
CREATE OR REPLACE FUNCTION public.guard_pod_inventory_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_mode text;
BEGIN
  -- ⛔ SECURITY DEFINER IS LOAD-BEARING HERE, NOT STYLISTIC (Cody, Article 4).
  --    refill_policy_params has RLS enabled with force=false and is owned by postgres, so a
  --    definer owned by postgres bypasses RLS and reads the dial reliably. As SECURITY INVOKER
  --    the dial read would return NO ROW under a restrictive policy, the COALESCE below would
  --    resolve 'off', and THE GUARD WOULD FAIL OPEN SILENTLY. Do not "simplify" this to INVOKER.
  SELECT pod_inventory_write_freeze INTO v_mode FROM public.refill_policy_params LIMIT 1;
  -- ⚠️ DECLARED FAIL-OPEN (Cody, Article 4). A missing params row disarms the guard. This is
  --    deliberate and matches every other dial in this system (preflight_enforcement,
  --    spot_buy_cap_enforcement); failing closed would take every pod_inventory write down on a
  --    config accident. It is stated because an UNSTATED fail-open in a security guard is how the
  --    next reviewer is misled.
  v_mode := COALESCE(v_mode, 'off');

  IF v_mode = 'off' THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  IF v_mode = 'frozen' THEN
    RAISE EXCEPTION
      'pod_inventory % refused: the table is FROZEN read-only historical (PRD-110 P1.4). Composition truth is shelf_composition; movement truth is inventory_events.', TG_OP
      USING ERRCODE = '42501',
            HINT = 'refill_policy_params.pod_inventory_write_freeze = ''frozen''. Only CS may lower it.';
  END IF;

  IF current_setting('app.via_rpc', true) IS DISTINCT FROM 'true' THEN
    IF v_mode = 'warn' THEN
      RAISE WARNING
        'pod_inventory %: direct write outside a canonical RPC (write-freeze = warn). This will be REFUSED at ''block''.', TG_OP;
    ELSE
      RAISE EXCEPTION
        'pod_inventory % blocked: route through a canonical RPC (adjust_pod_inventory, remove_pod_inventory_batch, log_manual_refill, receive_dispatch_line, bulk_upsert_pod_inventory_from_log, ...). Set app.via_rpc=''true'' inside a SECURITY DEFINER wrapper.', TG_OP
        USING ERRCODE = '42501',
              HINT = 'Constitution Article 3 + PRD-110 P1.4. Mirrors trg_block_direct_pod_inventory_insert, which has guarded INSERT since PRD-012.';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_guard_pod_inventory_write ON public.pod_inventory;
CREATE TRIGGER trg_guard_pod_inventory_write
  BEFORE UPDATE OR DELETE ON public.pod_inventory
  FOR EACH ROW EXECUTE FUNCTION public.guard_pod_inventory_write();

-- ─────────────────────────────────────────────────────────────────────────────
-- (c) THE REVOKE — direct client write privileges
-- ─────────────────────────────────────────────────────────────────────────────
-- Safe because every one of the 14 writers is SECURITY DEFINER owned by postgres, and because
-- all five FE call sites were read and are SELECT-only.
-- ⚠️ service_role is DELIBERATELY LEFT ALONE: it is the n8n/break-glass path, this leg cannot
--    read the n8n flows to prove none of them writes, and revoking a privilege whose consumers
--    are unverifiable is how a nightly job dies silently at 02:00. The write-guard covers it
--    instead — which is the point of having a guard as well as a revoke.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.pod_inventory FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.pod_inventory FROM anon;

-- ⚠️ Cody, Article 3: the RLS policy `field_write_pod_inventory` (FOR ALL) SURVIVES this revoke
--    and now grants what the GRANT denies. It is not exploitable - privilege is checked before
--    policy - but a live ALL-policy on a protected table reads to the next person as an
--    authorised write path. It is NOT dropped here (Article 12, forward-only, and dropping a
--    policy is destructive); it is labelled instead.
COMMENT ON POLICY field_write_pod_inventory ON public.pod_inventory IS
  'INERT FOR WRITES since PRD-110 DR-3 (2026-08-07): INSERT/UPDATE/DELETE/TRUNCATE were REVOKEd '
  'from authenticated, and table privilege is checked BEFORE policy. This policy grants nothing '
  'a client can reach. Writes go through the 14 SECURITY DEFINER canonical writers only. '
  'Retained rather than dropped per Article 12.';

-- ─────────────────────────────────────────────────────────────────────────────
-- (d) THE DAILY-DELTA REPORT — BUILD SPEC P1.4 line 68's "report daily deltas"
-- ─────────────────────────────────────────────────────────────────────────────
-- Answers the only question that matters before the freeze: is the replacement carrying the
-- load yet? It reports pod_inventory write volume ALONGSIDE inventory_events volume for the
-- same day, so a zero in the right-hand column is visible rather than absent.
CREATE OR REPLACE VIEW public.v_pod_inventory_daily_delta_v3 AS
WITH d AS (
  SELECT generate_series(CURRENT_DATE - 29, CURRENT_DATE, interval '1 day')::date AS day
),
pi AS (
  SELECT created_at::date                                          AS day,
         count(*)                                                  AS pod_writes,
         -- ⛔ operation is stored LOWERCASE ('insert','update'); 'delete' has NEVER been
         --    written, which is itself worth reporting rather than assuming.
         count(*) FILTER (WHERE lower(operation) = 'insert')        AS pod_inserts,
         count(*) FILTER (WHERE lower(operation) = 'update')        AS pod_updates,
         count(*) FILTER (WHERE lower(operation) = 'delete')        AS pod_deletes,
         count(DISTINCT machine_id)                                 AS machines_touched,
         count(DISTINCT shelf_id)                                   AS shelves_touched,
         count(DISTINCT source)                                     AS distinct_sources,
         -- ⛔ RENAMED PER CODY (Article 16). This is WRITE VOLUME, never inventory truth.
         --    "Live shelf stock" is a registered metric owned by v_live_shelf_stock; a column
         --    named like a unit total on a pod_inventory-derived object is exactly the invitation
         --    to inline re-derivation that Article 16 exists to block.
         COALESCE(sum(delta), 0)                                    AS audited_delta_units_writevol
  FROM public.pod_inventory_audit_log
  WHERE created_at >= CURRENT_DATE - 29
  GROUP BY 1
),
ie AS (
  SELECT ts::date        AS day,
         count(*)        AS event_writes,
         count(DISTINCT machine_id) AS event_machines
  FROM public.inventory_events
  WHERE ts >= CURRENT_DATE - 29
  GROUP BY 1
)
SELECT d.day,
       COALESCE(pi.pod_writes, 0)        AS pod_inventory_writes,
       COALESCE(pi.pod_inserts, 0)       AS pod_inventory_inserts,
       COALESCE(pi.pod_updates, 0)       AS pod_inventory_updates,
       COALESCE(pi.pod_deletes, 0)       AS pod_inventory_deletes,
       COALESCE(pi.machines_touched, 0)  AS machines_touched,
       COALESCE(pi.shelves_touched, 0)   AS shelves_touched,
       COALESCE(pi.distinct_sources, 0)  AS distinct_write_sources,
       COALESCE(pi.audited_delta_units_writevol, 0) AS audited_delta_units_writevol,
       COALESCE(ie.event_writes, 0)      AS inventory_events_writes,
       COALESCE(ie.event_machines, 0)    AS inventory_events_machines,
       -- ⭐ THE HONEST HEADLINE. 'not_ready' is the expected reading today and the report is
       --    built to keep saying it until the replacement actually takes over.
       CASE WHEN COALESCE(pi.pod_writes, 0) = 0                  THEN 'quiet'
            WHEN COALESCE(ie.event_writes, 0) = 0                THEN 'not_ready'
            WHEN COALESCE(ie.event_writes, 0)
                 < COALESCE(pi.pod_writes, 0) * 0.5              THEN 'lagging'
            ELSE                                                      'tracking'
       END                               AS freeze_readiness,
       (SELECT pod_inventory_write_freeze FROM public.refill_policy_params LIMIT 1)
                                         AS freeze_dial
FROM d
LEFT JOIN pi ON pi.day = d.day
LEFT JOIN ie ON ie.day = d.day
ORDER BY d.day DESC;

COMMENT ON VIEW public.v_pod_inventory_daily_delta_v3 IS
  'PRD-110 DR-3 / BUILD SPEC P1.4. Daily pod_inventory write volume beside inventory_events '
  'volume, so the freeze decision is made on whether the replacement is carrying the load. '
  'freeze_readiness = not_ready while inventory_events is silent. 30-day rolling window.';

GRANT SELECT ON public.v_pod_inventory_daily_delta_v3 TO authenticated;
