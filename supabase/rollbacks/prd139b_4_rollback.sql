-- Rollback for 20261006060234_prd139b_4_sensitive_data_audit.sql

DROP TRIGGER IF EXISTS tg_audit_machine_name_aliases ON public.machine_name_aliases;
DROP TRIGGER IF EXISTS tg_audit_product_name_conventions ON public.product_name_conventions;
DROP TRIGGER IF EXISTS tg_audit_suppliers ON public.suppliers;
DROP TRIGGER IF EXISTS tg_audit_pod_products ON public.pod_products;

DROP VIEW IF EXISTS public.v_suppliers_full;

REVOKE SELECT (supplier_id, supplier_code, supplier_acronym, supplier_name, contact_person,
  contact_email, contact_phone, address, country, category, products_supplied,
  return_options, currency, payment_type, contract_start_date, contract_end_date,
  status, rating, notes, created_at, updated_at, last_edited_at, procurement_type)
  ON public.suppliers FROM authenticated;
GRANT SELECT ON public.suppliers TO authenticated;

DROP POLICY IF EXISTS admins_manage_suppliers ON public.suppliers;
CREATE POLICY admins_manage_suppliers ON public.suppliers
  FOR ALL
  TO public
  USING (EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['operator_admin', 'superadmin', 'manager', 'warehouse'])
  ));

DROP POLICY IF EXISTS sim_cards_admin_write ON public.sim_cards;
CREATE POLICY sim_cards_warehouse_write ON public.sim_cards
  FOR ALL
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['warehouse', 'manager', 'superadmin'])
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['warehouse', 'manager', 'superadmin'])
  ));
