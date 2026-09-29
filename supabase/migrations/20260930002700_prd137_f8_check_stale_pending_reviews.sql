-- PRD-137 F8, 2026-09-30: driver Pending Reviews (pod_inventory_edits, status='pending') needs
-- to collapse duplicates and escalate items older than 48h. Evidence: 20 driver Pending Reviews
-- 5-6 days old before tonight's manual cleanup; VML-1004 A03 Red Bull return sat 102h.
--
-- This adds detection + a warning alert for both conditions (matching the check_* pattern already
-- used by check_ambiguous_function_overloads and check_expiry_pull_candidates), plus a nightly
-- cron run. It does NOT auto-reject duplicates: rejecting a driver's pending review is a real,
-- one-way action on a protected-adjacent record, so duplicates are surfaced (newest_edit_id vs
-- older_duplicate_ids) for a WM/CS decision, the same way item i's ALJLT duplicate was resolved
-- by hand earlier tonight, not auto-collapsed by a migration.
--
-- Rollback: supabase/rollback/20260930002700_prd137_f8_check_stale_pending_reviews_rollback.sql
CREATE OR REPLACE FUNCTION public.check_stale_pending_reviews()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_stale_rows jsonb;
  v_stale_n int;
  v_dup_rows jsonb;
  v_dup_n int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'edit_id', pie.edit_id, 'machine_name', m.official_name,
           'boonz_product_name', bp.boonz_product_name, 'edit_type', pie.edit_type,
           'quantity_update', pie.quantity_update, 'created_at', pie.created_at,
           'age_hours', round(extract(epoch from (now()-pie.created_at))/3600, 1))), '[]'::jsonb),
         COUNT(*)
    INTO v_stale_rows, v_stale_n
  FROM pod_inventory_edits pie
  JOIN machines m ON m.machine_id = pie.machine_id
  JOIN boonz_products bp ON bp.product_id = pie.boonz_product_id
  WHERE pie.status = 'pending' AND pie.created_at < now() - interval '48 hours';

  WITH dups AS (
    SELECT machine_id, boonz_product_id, edit_type, array_agg(edit_id ORDER BY created_at) AS edit_ids, count(*) AS n
    FROM pod_inventory_edits
    WHERE status = 'pending'
    GROUP BY machine_id, boonz_product_id, edit_type
    HAVING count(*) > 1
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'machine_name', m.official_name, 'boonz_product_name', bp.boonz_product_name,
           'edit_type', d.edit_type, 'edit_ids', d.edit_ids, 'count', d.n,
           'newest_edit_id', d.edit_ids[d.n], 'older_duplicate_ids', d.edit_ids[1:d.n-1])), '[]'::jsonb),
         COUNT(*)
    INTO v_dup_rows, v_dup_n
  FROM dups d
  JOIN machines m ON m.machine_id = d.machine_id
  JOIN boonz_products bp ON bp.product_id = d.boonz_product_id;

  IF v_stale_n > 0 THEN
    PERFORM safe_monitoring_alert('stale_pending_reviews', 'warning',
      jsonb_build_object('checked_at', now(), 'count', v_stale_n, 'rows', v_stale_rows));
  END IF;
  IF v_dup_n > 0 THEN
    PERFORM safe_monitoring_alert('duplicate_pending_reviews', 'warning',
      jsonb_build_object('checked_at', now(), 'count', v_dup_n, 'rows', v_dup_rows,
        'note', 'Surfaced for WM/CS review, not auto-rejected -- keep the newest_edit_id, reject the older_duplicate_ids after confirming they are truly the same physical count'));
  END IF;

  RETURN jsonb_build_object('checked_at', now(),
    'stale_count', v_stale_n, 'stale_rows', v_stale_rows,
    'duplicate_group_count', v_dup_n, 'duplicate_groups', v_dup_rows);
END;
$function$;

SELECT cron.schedule(
  'check_stale_pending_reviews_nightly',
  '55 20 * * *',
  $$ SELECT public.check_stale_pending_reviews(); $$
);
