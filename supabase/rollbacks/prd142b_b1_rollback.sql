-- Rollback for prd142b_b1_posture_params: drop the view and helper, remove the five flags.
DROP VIEW IF EXISTS public.v_machine_posture_params;
DROP FUNCTION IF EXISTS public.prd142_setting_on(text, boolean);
DELETE FROM public.refill_settings WHERE setting_key IN ('prd142_fill_depth_enabled', 'prd142_swap_mode_enabled',
  'prd142_swap_guard_enabled', 'prd142_picker_multiplier_enabled', 'prd142_procurement_posture_enabled');
