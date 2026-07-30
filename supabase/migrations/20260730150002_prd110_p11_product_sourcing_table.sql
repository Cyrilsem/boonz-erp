-- PRD-110 P1.1(ii) - product_sourcing: the per-(machine, pod, sku) sourcing edge (WS-J1).
--
-- WHY THIS EXISTS (S-10, the defect it deletes): `engine_add_pod` scopes availability to
-- warehouse_id = ANY(ARRAY[primary_warehouse_id, secondary_warehouse_id]). Three VOX machines
-- (ACTIVATEMCC-1037, MPMCC-1054, MPMCC-1058) are served by WH_CENTRAL with no secondary, so a
-- VOXSOURCE-999 sentinel at WH_MCC/WH_MM is structurally invisible to them and their venue-supplied
-- products block as blocked_no_wh forever. Minting the sentinel at WH_CENTRAL instead would grant
-- phantom availability to all 26 WH_CENTRAL-served machines, including fully-managed offices.
-- product_sourcing removes the whole question: source='venue' means UNCONSTRAINED BY DEFINITION,
-- so a machine's warehouse assignment stops deciding whether a venue-supplied product is plannable.
--
-- Dara design:
--   D1 uuid PK. D2 append-only: history is the product (WS-J1 "religiously tracked" = the audit
--      trail is automatic, not procedural). A supersede writes valid_to+status on the old row and
--      INSERTs the new one; `source` itself is NEVER updated in place.
--   D3 boonz_product_id NULL = a POD-GRAIN edge covering every variant of that pod on that machine.
--      Not "missing": it is the correct grain when the venue supplies the pod and the SKU mix is
--      not Boonz's to know (the J2 composition problem).
--   D4 FKs RESTRICT on the identity keys (a machine/pod with live sourcing edges must not vanish
--      underneath the planner), SET NULL on the actor.
--   D5 partial unique index = at most one Active edge per (machine, pod, sku-or-pod-grain).
--
-- Cody class (a) new table + (b) writer DEFINER.
--   Article 1  - set_product_sourcing_v3 is the single canonical write path (backfill genesis in
--                20260730150003 goes through its own DEFINER, never a raw INSERT).
--   Article 2  - RLS enabled. Article 3 - NO write policy exists at all, so `authenticated` can
--                only ever read; the DEFINER runs as owner and is structurally the only writer.
--   Article 7  - append-only is enforced by a TRIGGER, not by RLS. This is the important one:
--                the canonical writer is SECURITY DEFINER and therefore BYPASSES RLS, so an
--                RLS-only "no UPDATE policy" would protect nothing against the writer itself.
--                tg_product_sourcing_append_only refuses every DELETE and every UPDATE that
--                touches anything except the supersede pair (status, valid_to).
--   Article 8  - generic audit_log_write trigger attached.
--   Article 14 - NOT a materialized query result. It holds sourcing DECISIONS (and their history)
--                that no view can derive: product_mapping.source_of_supply is the seed, but the
--                whole point is that CS edits these edges per machine afterwards. Same standing as
--                blocked_demand. No ADR required.
--   Article 16 - registered as the canonical object for "product sourcing per machine"; consumers
--                read v_product_sourcing_current / resolve_product_sourcing_v3, never the raw table.

CREATE TABLE IF NOT EXISTS public.product_sourcing (
  sourcing_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id        uuid NOT NULL REFERENCES public.machines(machine_id)         ON DELETE RESTRICT,
  pod_product_id    uuid NOT NULL REFERENCES public.pod_products(pod_product_id) ON DELETE RESTRICT,
  boonz_product_id  uuid     NULL REFERENCES public.boonz_products(product_id)   ON DELETE RESTRICT,
  source            text NOT NULL CHECK (source IN ('boonz_wh','venue','partner')),
  status            text NOT NULL DEFAULT 'Active' CHECK (status IN ('Active','Superseded')),
  valid_from        timestamptz NOT NULL DEFAULT now(),
  valid_to          timestamptz NULL,
  changed_by        uuid NULL REFERENCES public.user_profiles(id)                ON DELETE SET NULL,
  origin            text NOT NULL DEFAULT 'manual'
                      CHECK (origin IN ('backfill','manual','engine','import')),
  reason            text NOT NULL CHECK (length(btrim(reason)) >= 10),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_sourcing_status_pair CHECK (
    (status = 'Active'    AND valid_to IS NULL)
 OR (status = 'Superseded' AND valid_to IS NOT NULL))
);

COMMENT ON TABLE public.product_sourcing IS
  'PRD-110 P1.1 (WS-J1). Append-only sourcing edge per (machine, pod_product, boonz_product?). '
  'boonz_wh = planner constrains on real Boonz warehouse stock. venue = the venue supplies it, so '
  'the planner treats it as UNCONSTRAINED by definition (this is what retires the VOXSOURCE-999 '
  'sentinels at P1.3). partner = partner_managed machine, Boonz holds no inventory and the engine '
  'plans nothing. Written ONLY by set_product_sourcing_v3 / backfill_product_sourcing_v3. '
  'Read through v_product_sourcing_current or resolve_product_sourcing_v3, never directly.';
COMMENT ON COLUMN public.product_sourcing.boonz_product_id IS
  'NULL = POD-GRAIN edge: applies to every variant of this pod on this machine. Correct (not '
  'missing) when the venue supplies the pod and the SKU mix is not observable - see WS-J2.';
COMMENT ON COLUMN public.product_sourcing.source IS
  'NEVER updated in place. A change supersedes the current row (status=Superseded, valid_to=now) '
  'and inserts a new Active row, so the history is the audit trail (WS-J1).';
COMMENT ON COLUMN public.product_sourcing.origin IS
  'backfill = derived from product_mapping.source_of_supply at P1.1 genesis. manual = a human FE '
  'edit. Lets a later leg tell a seeded guess apart from a decision someone actually made.';

-- Serves: the "current edge" lookup in resolve_product_sourcing_v3 and the uniqueness invariant.
-- COALESCE on boonz_product_id because NULL (pod-grain) must collide with itself, and a NULL
-- column in a plain unique index would not.
CREATE UNIQUE INDEX IF NOT EXISTS uq_product_sourcing_active
  ON public.product_sourcing
     (machine_id, pod_product_id, COALESCE(boonz_product_id,'00000000-0000-0000-0000-000000000000'::uuid))
  WHERE status = 'Active';

-- Serves: the per-machine sourcing grid in FE (P1.1 Stax ticket) and shelf_state (P1.2).
CREATE INDEX IF NOT EXISTS idx_product_sourcing_machine_active
  ON public.product_sourcing (machine_id, pod_product_id) WHERE status = 'Active';

-- Serves: "where is this SKU venue-sourced?" fleet-wide questions (sentinel retirement, P1.3).
CREATE INDEX IF NOT EXISTS idx_product_sourcing_sku_source
  ON public.product_sourcing (boonz_product_id, source) WHERE status = 'Active';

ALTER TABLE public.product_sourcing ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS product_sourcing_select ON public.product_sourcing;
CREATE POLICY product_sourcing_select ON public.product_sourcing
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles up
                 WHERE up.id = (SELECT auth.uid())
                   AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager','field_staff'])));

-- Article 7 enforcement (see header): RLS cannot bind the DEFINER writer, a trigger can.
CREATE OR REPLACE FUNCTION public.tg_product_sourcing_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'product_sourcing is append-only: DELETE refused (sourcing_id %). Supersede instead.',
      OLD.sourcing_id;
  END IF;

  -- The ONLY legal UPDATE is the supersede pair.
  IF NEW.sourcing_id      IS DISTINCT FROM OLD.sourcing_id
  OR NEW.machine_id       IS DISTINCT FROM OLD.machine_id
  OR NEW.pod_product_id   IS DISTINCT FROM OLD.pod_product_id
  OR NEW.boonz_product_id IS DISTINCT FROM OLD.boonz_product_id
  OR NEW.source           IS DISTINCT FROM OLD.source
  OR NEW.valid_from       IS DISTINCT FROM OLD.valid_from
  OR NEW.origin           IS DISTINCT FROM OLD.origin
  OR NEW.reason           IS DISTINCT FROM OLD.reason
  OR NEW.created_at       IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'product_sourcing is append-only: only (status, valid_to) may be updated '
                    '(the supersede). Attempted change on sourcing_id %.', OLD.sourcing_id;
  END IF;

  IF OLD.status = 'Superseded' THEN
    RAISE EXCEPTION 'product_sourcing: sourcing_id % is already Superseded and is immutable.',
      OLD.sourcing_id;
  END IF;

  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS tg_product_sourcing_append_only ON public.product_sourcing;
CREATE TRIGGER tg_product_sourcing_append_only
  BEFORE UPDATE OR DELETE ON public.product_sourcing
  FOR EACH ROW EXECUTE FUNCTION public.tg_product_sourcing_append_only();

-- BUILD SPEC P1.1 constraint triggers: partner_managed => no boonz_wh edges;
-- fully_managed => no venue edges. INERT while machines.operating_model IS NULL, which is the
-- state the whole fleet is in until CS applies the parked backfill - deliberate, so P1.1's own
-- genesis backfill cannot be blocked by a classification CS has not made yet.
CREATE OR REPLACE FUNCTION public.tg_product_sourcing_model_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE v_model text;
BEGIN
  SELECT m.operating_model INTO v_model FROM public.machines m WHERE m.machine_id = NEW.machine_id;

  IF v_model IS NULL THEN
    RETURN NEW;                                   -- unclassified machine: rule is inert, by design
  END IF;

  IF v_model = 'partner_managed' AND NEW.source = 'boonz_wh' THEN
    RAISE EXCEPTION 'product_sourcing: machine % is partner_managed and may hold no boonz_wh edge '
                    '(WS-J1: partner machines carry zero Boonz inventory records).', NEW.machine_id;
  END IF;

  IF v_model = 'fully_managed' AND NEW.source = 'venue' THEN
    RAISE EXCEPTION 'product_sourcing: machine % is fully_managed and may hold no venue edge '
                    '(WS-J1: on a fully-managed machine all products are Boonz-sourced).', NEW.machine_id;
  END IF;

  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS tg_product_sourcing_model_guard ON public.product_sourcing;
CREATE TRIGGER tg_product_sourcing_model_guard
  BEFORE INSERT OR UPDATE ON public.product_sourcing
  FOR EACH ROW EXECUTE FUNCTION public.tg_product_sourcing_model_guard();

-- Article 8: universal audit.
DROP TRIGGER IF EXISTS tg_audit_product_sourcing ON public.product_sourcing;
CREATE TRIGGER tg_audit_product_sourcing
  AFTER INSERT OR UPDATE OR DELETE ON public.product_sourcing
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('sourcing_id');

GRANT SELECT ON public.product_sourcing TO authenticated;
