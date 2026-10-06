-- PRD-139b Item 4: sensitive master data and audit.
--
-- Investigated before writing this: sim_cards_warehouse_write (ALL, role IN
-- warehouse/manager/superadmin) currently gives warehouse full read/write on
-- sim_cards including puk1/puk2/contact_number. Confirmed via grep that no
-- warehouse-reachable FE route (warehouse never reaches /app/* at all per the main
-- middleware, and /field/config/sims is now admins-only per this same PRD's Item 3)
-- reads sim_cards -- so no replacement SECURITY DEFINER read helper is needed.
--
-- suppliers: admins_manage_suppliers (ALL, role IN operator_admin/superadmin/
-- manager/warehouse) gives warehouse full write; authenticated_read_suppliers
-- (SELECT true) exposes every column including bank_details/payment_terms to any
-- authenticated session regardless of app role (RLS is row-level, not column-level,
-- so this could not be fixed with a policy alone). The one warehouse-reachable FE
-- read site, field/orders/new/page.tsx, already selects only non-sensitive columns
-- (supplier_id, supplier_name, supplier_code, contact_email, procurement_type) -- no
-- FE change needed there. field/config/suppliers/page.tsx does select("*") but that
-- route is now admins-only per Item 3's middleware; app/suppliers/page.tsx (operator
-- admin/manager/superadmin/finance) also does select("*").

-- ============================================================
-- sim_cards: drop warehouse from the write policy. Admins only from here on.
-- ============================================================
DROP POLICY IF EXISTS sim_cards_warehouse_write ON public.sim_cards;
CREATE POLICY sim_cards_admin_write ON public.sim_cards
  FOR ALL
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['manager', 'superadmin'])
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['manager', 'superadmin'])
  ));
-- sim_cards_admin_all (operator_admin) is untouched and still in effect.

-- ============================================================
-- suppliers: remove warehouse from the write policy; column-mask bank_details and
-- payment_terms so only admins can read them, regardless of which row-level policy
-- let the row through.
-- ============================================================
DROP POLICY IF EXISTS admins_manage_suppliers ON public.suppliers;
CREATE POLICY admins_manage_suppliers ON public.suppliers
  FOR ALL
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['operator_admin', 'superadmin', 'manager'])
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['operator_admin', 'superadmin', 'manager'])
  ));
-- authenticated_read_suppliers (SELECT true) stays -- it only covers row visibility;
-- column-level revoke below is what actually hides bank_details/payment_terms.

-- A column-only REVOKE is not enough: `authenticated` also held a table-wide SELECT
-- grant, which still covers every column regardless of a column-specific revoke
-- (confirmed by a failing rolled-back test before this migration was finalized).
-- Must revoke the table-wide grant and re-grant an explicit column list instead.
REVOKE SELECT ON public.suppliers FROM authenticated;
GRANT SELECT (supplier_id, supplier_code, supplier_acronym, supplier_name, contact_person,
  contact_email, contact_phone, address, country, category, products_supplied,
  return_options, currency, payment_type, contract_start_date, contract_end_date,
  status, rating, notes, created_at, updated_at, last_edited_at, procurement_type)
  ON public.suppliers TO authenticated;

-- Replacement read surface for the two admin-facing list pages that need the full
-- row (the view is owned by the migration-running role, which still has full column
-- access to the base table regardless of the revoke above, so the CASE expressions
-- below can read the real values and decide whether to expose them).
CREATE OR REPLACE VIEW public.v_suppliers_full AS
SELECT
  s.supplier_id, s.supplier_code, s.supplier_acronym, s.supplier_name,
  s.contact_person, s.contact_email, s.contact_phone, s.address, s.country,
  s.category, s.products_supplied,
  CASE WHEN EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['operator_admin', 'superadmin', 'manager'])
  ) THEN s.payment_terms ELSE NULL END AS payment_terms,
  s.return_options, s.currency, s.payment_type,
  CASE WHEN EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['operator_admin', 'superadmin', 'manager'])
  ) THEN s.bank_details ELSE NULL END AS bank_details,
  s.contract_start_date, s.contract_end_date, s.status, s.rating, s.notes,
  s.created_at, s.updated_at, s.last_edited_at, s.procurement_type
FROM public.suppliers s;

GRANT SELECT ON public.v_suppliers_full TO authenticated;

-- ============================================================
-- Audit triggers, same pattern as boonz_products/machines/product_mapping/sim_cards.
-- ============================================================
DROP TRIGGER IF EXISTS tg_audit_pod_products ON public.pod_products;
CREATE TRIGGER tg_audit_pod_products
  AFTER INSERT OR DELETE OR UPDATE ON public.pod_products
  FOR EACH ROW EXECUTE FUNCTION audit_log_write('pod_product_id');

DROP TRIGGER IF EXISTS tg_audit_suppliers ON public.suppliers;
CREATE TRIGGER tg_audit_suppliers
  AFTER INSERT OR DELETE OR UPDATE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION audit_log_write('supplier_id');

DROP TRIGGER IF EXISTS tg_audit_product_name_conventions ON public.product_name_conventions;
CREATE TRIGGER tg_audit_product_name_conventions
  AFTER INSERT OR DELETE OR UPDATE ON public.product_name_conventions
  FOR EACH ROW EXECUTE FUNCTION audit_log_write('id');

DROP TRIGGER IF EXISTS tg_audit_machine_name_aliases ON public.machine_name_aliases;
CREATE TRIGGER tg_audit_machine_name_aliases
  AFTER INSERT OR DELETE OR UPDATE ON public.machine_name_aliases
  FOR EACH ROW EXECUTE FUNCTION audit_log_write('alias_id');
