-- PRD-015 Phase B / AC#2 — repoint the 8pm Dubai cron (job 13) from auto_generate_draft
-- (which re-picks and therefore wipes Gate-0 confirmation) to build_draft_for_confirmed,
-- which builds only over confirmed+included machines and exits cleanly when none are
-- confirmed. Schedule unchanged (0 16 * * * UTC = 20:00 Asia/Dubai).
-- auto_generate_draft is retained for explicit manual "pick + confirm + build in one shot"
-- and documented as re-picking (must NOT be wired to a cron under the human-confirm model).
-- Depends on 20260531091000_phaseG_build_draft_for_confirmed. NOT YET APPLIED.

SELECT cron.alter_job(
  13,
  command => 'SELECT public.build_draft_for_confirmed(CURRENT_DATE + 1);'
);

COMMENT ON FUNCTION public.auto_generate_draft(date) IS
  'MANUAL-ONLY (PRD-015 AC#2). Chains pick_machines_for_refill -> engine_add_pod -> '
  'engine_swap_pod, so it RE-PICKS and resets Gate-0 confirmed_at. Do NOT wire to a cron '
  'under the human-confirm model (feedback_cron_keep_human_confirm). The 8pm cron (job 13) '
  'now calls build_draft_for_confirmed, which never re-picks. Use auto_generate_draft only '
  'for an explicit operator "pick + confirm + build in one shot".';
