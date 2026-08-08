-- PRD-112 unit 2a — day_close_events
--
-- The reviewable note the driver's edge-absorbed changes surface into at end of day.
-- One row per thing CS has to look at before the day is closed. Deliberately
-- lightweight: it records WHAT happened and WHO saw it, never stock truth. Stock
-- moves only when CS acknowledges (see the acknowledge RPC in 20260808231000).
--
-- Shape is fixed by PRD-112 §3.3 and §5 (the v3 edit-miner consumes this table
-- unchanged at cutover): id, event_date, machine_id, dispatch_id, kind, payload,
-- created_by, acknowledged_at, acknowledged_by.

CREATE TABLE IF NOT EXISTS public.day_close_events (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_date       date        NOT NULL,
  machine_id       uuid        NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  dispatch_id      uuid        REFERENCES public.refill_dispatching(dispatch_id) ON DELETE RESTRICT,
  kind             text        NOT NULL,
  payload          jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_by       uuid        REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  acknowledged_at  timestamptz,
  acknowledged_by  uuid        REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  CONSTRAINT day_close_events_kind_chk CHECK (
    kind = ANY (ARRAY['substitution','not_filled','shortfall','spot_buy','stock_unverified'])
  ),
  -- An acknowledgement is a pair or it is nothing. Half-stamped rows would let the
  -- panel show "closed by nobody".
  CONSTRAINT day_close_events_ack_pair_chk CHECK (
    (acknowledged_at IS NULL AND acknowledged_by IS NULL)
    OR (acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL)
  )
);

COMMENT ON TABLE public.day_close_events IS
  'PRD-112 §3.3. Day-close review queue: one row per driver-absorbed change or gap. '
  'Written only by driver_substitute_dispatch_line; acknowledged only by '
  'acknowledge_day_close_event. Never carries stock truth - the acknowledge is what '
  'moves pod_inventory, via adjust_pod_inventory.';
COMMENT ON COLUMN public.day_close_events.payload IS
  'Free-shape evidence for the panel: old/new product, qty, reason, driver, review flags, '
  'and (after acknowledge) pod_action + the adjust_pod_inventory result.';

-- The panel always reads one day at a time, filtered to still-open rows.
CREATE INDEX IF NOT EXISTS idx_day_close_events_date_kind
  ON public.day_close_events (event_date DESC, kind);
CREATE INDEX IF NOT EXISTS idx_day_close_events_open
  ON public.day_close_events (event_date DESC)
  WHERE acknowledged_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_day_close_events_dispatch
  ON public.day_close_events (dispatch_id);

-- ── RLS ──────────────────────────────────────────────────────────────────────
-- Read for any signed-in staff member (the driver should be able to see that his
-- change landed). No INSERT/UPDATE/DELETE policy exists at all: the two SECURITY
-- DEFINER RPCs are the only writers, and they are owner-run so RLS does not apply
-- to them. Article 1 single-writer, enforced by the absence of a policy rather
-- than by a policy that could later be widened.
ALTER TABLE public.day_close_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS day_close_events_select ON public.day_close_events;
CREATE POLICY day_close_events_select ON public.day_close_events
  FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) IS NOT NULL);

REVOKE ALL ON public.day_close_events FROM PUBLIC, anon;

-- ⛔ S-308: a table created in `public` is BORN with INSERT/UPDATE/DELETE granted
-- to `authenticated` by the postgres default ACL (authenticated=arwdDxtm). The
-- REVOKE above is the S-268 idiom and does NOT touch a grant held by
-- `authenticated`, and GRANT SELECT does not narrow it either. Article 3
-- compliance needs this revoke explicitly, by name. Verified post-apply by
-- reading role_table_grants back.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.day_close_events FROM authenticated;
GRANT SELECT ON public.day_close_events TO authenticated;

-- ── Article 8: universal audit ───────────────────────────────────────────────
-- Both writers set app.via_rpc / app.rpc_name, so the generic trigger captures
-- every insert and every acknowledge into write_audit_log. Same binding every
-- sibling table in this family carries (tg_audit_machines_to_visit,
-- tg_audit_pod_refill_plan, tg_audit_blocked_demand, tg_audit_refill_plan_output).
DROP TRIGGER IF EXISTS tg_audit_day_close_events ON public.day_close_events;
CREATE TRIGGER tg_audit_day_close_events
  AFTER INSERT OR UPDATE OR DELETE ON public.day_close_events
  FOR EACH ROW EXECUTE FUNCTION audit_log_write('id');
