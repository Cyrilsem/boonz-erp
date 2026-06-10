-- PRD-1b (Procurement Brain v3) — enforce the canonical write path on purchase_orders.
-- Migration name: phasef_proc_po_rls_writes_rpc_only
-- Articles: 1 (single canonical write path), 3 (no direct authenticated writes to a protected entity).
--
-- The `warehouse_manage_pos` policy granted ALL commands (incl. INSERT/UPDATE/DELETE) to
-- warehouse/operator_admin/superadmin/manager directly on purchase_orders. That was the open
-- door that let the /app/procurement page insert PO lines straight from the client, bypassing
-- create_purchase_order AND the PRD-1 blocked-product guardrail. Both FE call sites are now
-- rerouted through create_purchase_order (canonical), so no legitimate authenticated write path
-- remains. Drop the policy so the ONLY ways to write purchase_orders are:
--   * the SECURITY DEFINER RPCs (create_purchase_order / edit_purchase_order_line /
--     cancel_po_line / receive_purchase_order), all owned by postgres → bypass RLS, and
--   * the service_role (service_role_all policy), for system/back-office tooling.
-- authenticated retains read access via the existing authenticated_read (SELECT) policy.
--
-- Safety verified before apply: purchase_orders has force_rls=false and is owned by postgres,
-- and all four writers are SECURITY DEFINER owned by postgres → they bypass RLS regardless of
-- this policy. No FE update/delete and no edge-function writes touch purchase_orders. This makes
-- the PRD-1 guardrail un-bypassable: there is no authenticated route to a PO line that skips the
-- create_purchase_order check.
--
-- NOTE (operational): if any n8n flow writes purchase_orders directly with a warehouse-role JWT
-- (rather than via create_purchase_order), this drop will break it — that flow is already a
-- Constitution Article 1/10 violation and must move to the RPC. None known in-repo.

DROP POLICY IF EXISTS warehouse_manage_pos ON public.purchase_orders;

COMMENT ON TABLE public.purchase_orders IS
  'Protected entity. WRITES are RPC-only: create_purchase_order (insert), edit_purchase_order_line (update of editable fields), cancel_po_line, receive_purchase_order — all SECURITY DEFINER. authenticated has SELECT only (authenticated_read); service_role retains full access (service_role_all). The direct-write policy warehouse_manage_pos was dropped 2026-06-10 (PRD-1b) so the PRD-1 blocked-product guardrail in create_purchase_order cannot be bypassed by a client insert.';
