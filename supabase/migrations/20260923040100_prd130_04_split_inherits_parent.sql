-- PRD-130 F4: driver variant split carries parent state.
--
-- NOT APPLIED YET. Touches a trigger on refill_dispatching insert paths shared with the field
-- app's driver split flow -- held to the same after-22:00 window as prd130_03, drafted now, CS
-- confirmed 2026-09-23 (Dubai 08:00) to add it to tonight's batch.
--
-- Root cause confirmed against live code before writing anything: `conserve_split_dispatch_quantity`
-- (a BEFORE INSERT trigger, trg_conserve_split_qty) already finds a matching packed parent row
-- (same machine/shelf/pod_product/boonz_product/dispatch_date/action) and decrements the parent's
-- remaining quantity by the new child's quantity -- but it does this ONLY when NEW.packed is
-- ALREADY true, and it never touches any other field on the child. It assumes whichever caller
-- inserted the child already set packed/pack_outcome/dispatched/source_kind/source_origin/
-- source_warehouse_id/from_warehouse_id/is_m2m/m2m_transfer_id correctly -- there is no
-- enforcement if a caller gets that wrong, which is exactly what F4 and G-SPLIT (already applied,
-- prd130_08) describe: a child inserted with packed=false while a packed parent exists.
--
-- `wm_confirm_line_split` (checked live) does NOT insert into refill_dispatching at all -- it is
-- a warehouse-side receipt split (creates warehouse_inventory/disposition_events rows only, never
-- touches refill_dispatching beyond setting wh_approved_at on the original line). F4's actual
-- target is any RPC that inserts a CHILD refill_dispatching row representing a split-off portion
-- of an existing packed row (the driver's own multi-variant split, PRD-053) -- this migration
-- fixes the shared trigger itself rather than any one calling RPC, per F4's own instruction
-- ("make the trigger enforce it for both paths").
--
-- Fix: the trigger's guard changes from `NEW.packed = true` (requires the caller already marked
-- it packed correctly, which is the exact case that can be wrong) to `COALESCE(NEW.created_by_edit,
-- false) = true` -- the same predicate G-SPLIT itself already uses to detect a manually-created
-- split/edit row, so this does not broaden the trigger's reach to ordinary engine/push-created
-- rows (which have created_by_edit=false or NULL). When a matching packed parent is found, the
-- trigger now force-inherits packed, pack_outcome, dispatched, source_kind, source_origin,
-- source_warehouse_id, from_warehouse_id, is_m2m, and m2m_transfer_id from the parent onto the
-- child (a BEFORE trigger, so NEW.field := ... is valid), in addition to the existing parent
-- quantity decrement. A split can never again land with packed=false while its parent is packed,
-- regardless of which RPC created it or what it set.
--
-- Smoke test (rolled back, 2026-09-23): inserted a deliberately-wrong child (packed=false,
-- pack_outcome=NULL, source_kind='unknown', created_by_edit=true, quantity=2) matching a real live
-- packed parent row (quantity=5, source_kind='wh', packed=true, pack_outcome='packed'). Result:
-- child inserted with packed/pack_outcome/source_kind/source_origin/source_warehouse_id/
-- from_warehouse_id all force-corrected to the parent's real values, and the parent's quantity
-- decremented 5 -> 3. Green. (First pass of this test checked the wrong dispatch_id -- the test
-- fixture date used has 17 near-identical rows from unrelated prior sessions sharing the same
-- machine/shelf/product/date/action; `ORDER BY created_at ASC LIMIT 1` correctly picks the actual
-- earliest one, which was not the row this session happened to check first. The trigger logic
-- itself was correct on the first attempt.)

CREATE OR REPLACE FUNCTION public.conserve_split_dispatch_quantity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_parent refill_dispatching%ROWTYPE;
BEGIN
  -- Skip M2M transfer rows — they are not multi-batch splits
  IF COALESCE(NEW.is_m2m, false) = true THEN
    RETURN NEW;
  END IF;

  -- PRD-130 F4: detect a split by created_by_edit=true (the same signal G-SPLIT already uses),
  -- not by trusting NEW.packed -- that trust is exactly the bug this migration closes.
  IF COALESCE(NEW.created_by_edit, false) = true
     AND NEW.quantity IS NOT NULL
     AND NEW.quantity > 0 THEN

    SELECT * INTO v_parent
    FROM refill_dispatching
    WHERE machine_id        = NEW.machine_id
      AND shelf_id          = NEW.shelf_id
      AND boonz_product_id  = NEW.boonz_product_id
      AND COALESCE(pod_product_id, '00000000-0000-0000-0000-000000000000'::uuid)
          = COALESCE(NEW.pod_product_id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND dispatch_date     = NEW.dispatch_date
      AND action            = NEW.action
      AND packed            = true
      AND quantity         >= NEW.quantity
      AND dispatch_id      <> COALESCE(NEW.dispatch_id, '00000000-0000-0000-0000-000000000000'::uuid)
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_parent.dispatch_id IS NOT NULL THEN
      NEW.packed              := v_parent.packed;
      NEW.pack_outcome        := v_parent.pack_outcome;
      NEW.dispatched          := v_parent.dispatched;
      NEW.source_kind         := v_parent.source_kind;
      NEW.source_origin       := v_parent.source_origin;
      NEW.source_warehouse_id := v_parent.source_warehouse_id;
      NEW.from_warehouse_id   := v_parent.from_warehouse_id;
      NEW.is_m2m              := v_parent.is_m2m;
      NEW.m2m_transfer_id     := v_parent.m2m_transfer_id;

      UPDATE refill_dispatching
      SET quantity = quantity - NEW.quantity
      WHERE dispatch_id = v_parent.dispatch_id;

      RAISE NOTICE 'conserve_split_dispatch_quantity: parent % decremented by %, child inherited packed=%, pack_outcome=%, source_kind=%',
        v_parent.dispatch_id, NEW.quantity, NEW.packed, NEW.pack_outcome, NEW.source_kind;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;
