-- PRD-139c Item 2: 7 public tables with no RLS and anon SELECT.
--
-- Grepped src/ and supabase/functions/ for all 7 names (weimi_product_alias,
-- the 3 product_mapping_backup_* tables, _prd129_baseline_20260922,
-- warehouse_audit_baseline) and found zero live application reads of any of
-- them, including weimi_product_alias. Per the spec's own instruction, that
-- means weimi_product_alias is revoked the same way as the backups, not
-- RLS-gated.
--
-- Checked pg_class.relacl directly: authenticated currently holds full
-- arwdDxtm (read/write/delete/truncate) on all 7 as a direct grant, not
-- through PUBLIC -- a live Article 3 exposure beyond what the spec named
-- (anon SELECT only). REVOKE ALL closes both anon's read and
-- authenticated's read-write-delete in one statement. No DROP.

REVOKE ALL ON TABLE public.weimi_product_alias FROM anon, authenticated;
REVOKE ALL ON TABLE public.product_mapping_backup_20260715 FROM anon, authenticated;
REVOKE ALL ON TABLE public.product_mapping_backup_20260718 FROM anon, authenticated;
REVOKE ALL ON TABLE public.product_mapping_backup_20260718b FROM anon, authenticated;
REVOKE ALL ON TABLE public.product_mapping_backup_20260718c FROM anon, authenticated;
REVOKE ALL ON TABLE public._prd129_baseline_20260922 FROM anon, authenticated;
REVOKE ALL ON TABLE public.warehouse_audit_baseline FROM anon, authenticated;
