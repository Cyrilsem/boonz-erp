-- Fleet reclassification follow-up (CS 2026-07-12): LVLUP names keep the
-- ORIGINAL machine numbers (1018/1048/2015), not the device last-4.
DO $$
DECLARE v jsonb;
BEGIN
  SELECT rename_machine(machine_id, 'LVLUP-1018-0000-G0', NULL,
    'CS correction 2026-07-12: keep original number 1018 (ex WH2-1018, device 82160805)', false)
  INTO v FROM machines WHERE official_name = 'LVLUP-0805-0000-G0';

  SELECT rename_machine(machine_id, 'LVLUP-1048-0000-P0', NULL,
    'CS correction 2026-07-12: keep original number 1048 (ex WH3_1048, device 8625110725)', false)
  INTO v FROM machines WHERE official_name = 'LVLUP-0725-0000-P0';

  SELECT rename_machine(machine_id, 'LVLUP-2015-0000-R0', NULL,
    'CS correction 2026-07-12: keep original number 2015 (ex WH3_2015, device 8625110925)', false)
  INTO v FROM machines WHERE official_name = 'LVLUP-0925-0000-R0';
END $$;
