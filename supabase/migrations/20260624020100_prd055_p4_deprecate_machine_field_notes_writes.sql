-- PRD-055 P4: retire the machine_field_notes write path (Article 13 — deprecate, do NOT drop).
-- Field Capture is removed from the FE (P3) and the 6 rows folded into refill_edit_signals (P2).
-- There is NO DB function and NO FE code that writes machine_field_notes (verified: zero pg_proc
-- references, zero src references), so there is no DEFINER writer to set SECURITY INVOKER. Instead
-- we durably close the write path at the grant layer: REVOKE INSERT/UPDATE/DELETE from authenticated
-- (service_role / backend bypass is unchanged). SELECT is kept so the archived rows stay readable
-- for the 90-day monitor window. Table NOT dropped (no data loss). Reversible via re-GRANT.
--
-- action_tracker writers (driver_propose_adjustment, driver_report_dispatch_outcome) are NOT retired:
-- the Issues board (v_action_tracker_issues) is kept for CS and the driver report flow continues.

REVOKE INSERT, UPDATE, DELETE ON public.machine_field_notes FROM authenticated;

COMMENT ON TABLE public.machine_field_notes IS
  'DEPRECATED 2026-06-23 (PRD-055): Field Capture retired; rows folded into refill_edit_signals source=field_note. Write path revoked from authenticated (SELECT kept). Retained read-only for 90-day monitor; do not drop before 2026-09-21.';
