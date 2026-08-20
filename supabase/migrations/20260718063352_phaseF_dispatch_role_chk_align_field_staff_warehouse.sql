-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- Documented in docs/architecture/CHANGELOG.md (~line 122) and MIGRATIONS_REGISTRY.md (~line 31):
-- widens both refill_dispatching_last_edited_role_chk and
-- refill_dispatching_edit_log_edited_by_role_check to additionally allow 'field_staff' +
-- 'warehouse', keeping legacy 'driver'/'warehouse_manager' for historical rows. Additive,
-- forward-only DROP+ADD. Fixes swap_shelf_pod/add_dispatch_row INSERTs being rejected for
-- field/warehouse users. Cody PASS; verified live via field_staff swap on WH1-2002.
-- Constraint defs below recovered verbatim from pg_get_constraintdef() on prod 2026-08-20.

ALTER TABLE public.refill_dispatching
  DROP CONSTRAINT IF EXISTS refill_dispatching_last_edited_role_chk;

ALTER TABLE public.refill_dispatching
  ADD CONSTRAINT refill_dispatching_last_edited_role_chk
  CHECK (
    (last_edited_by_role IS NULL) OR
    (last_edited_by_role = ANY (ARRAY[
      'driver'::text, 'warehouse_manager'::text, 'field_staff'::text, 'warehouse'::text,
      'operator_admin'::text, 'superadmin'::text, 'manager'::text, 'system'::text
    ]))
  );

ALTER TABLE public.refill_dispatching_edit_log
  DROP CONSTRAINT IF EXISTS refill_dispatching_edit_log_edited_by_role_check;

ALTER TABLE public.refill_dispatching_edit_log
  ADD CONSTRAINT refill_dispatching_edit_log_edited_by_role_check
  CHECK (
    edited_by_role = ANY (ARRAY[
      'driver'::text, 'warehouse_manager'::text, 'field_staff'::text, 'warehouse'::text,
      'operator_admin'::text, 'superadmin'::text, 'manager'::text, 'system'::text
    ])
  );
