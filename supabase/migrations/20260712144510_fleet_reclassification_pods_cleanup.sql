-- PRD-087 R9 — Fleet reclassification (CS approved 2026-07-12 chat).
-- Buckets: Active (untouched) / Office / DIP / China / Legacy.
-- Statuses collapse to Active|Inactive only (retires 'Warehouse' value and
-- the NULL-status leak into v_active_fleet's COALESCE(status,'Active')).
-- Physical whereabouts live in pod_location: 'Office' | 'DIP' | 'China' | 'Legacy'.

-- 1) LevelUp allocation renames (device last-4 → LVLUP names).
--    rename_machine = canonical PRD fn: ripples aliases, refill plans,
--    sim_cards, visits, terminal history, sales mapping.
DO $$
DECLARE v jsonb;
BEGIN
  SELECT rename_machine(machine_id, 'LVLUP-0805-0000-G0', NULL,
    'Fleet reclassification 2026-07-12: LevelUp allocation, device 82160805 (single door)', false)
  INTO v FROM machines WHERE official_name = 'WH2-1018-0000-W0';

  SELECT rename_machine(machine_id, 'LVLUP-0725-0000-P0', NULL,
    'Fleet reclassification 2026-07-12: LevelUp allocation, device 8625110725 (single door)', false)
  INTO v FROM machines WHERE official_name = 'WH3_1048_0000_W0';

  SELECT rename_machine(machine_id, 'LVLUP-0925-0000-R0', NULL,
    'Fleet reclassification 2026-07-12: LevelUp allocation, device 8625110925 (double door)', false)
  INTO v FROM machines WHERE official_name = 'WH3_2015_0000_W0';
END $$;

-- 2) Office/Central storage: LVLUP trio + WH1-2002 (device 82160816).
UPDATE machines
SET status = 'Inactive', pod_location = 'Office', include_in_refill = false, updated_at = now()
WHERE official_name IN
  ('LVLUP-0805-0000-G0','LVLUP-0725-0000-P0','LVLUP-0925-0000-R0','WH1-2002-0000-W0');

-- 3) Remaining Batch-2 WH3 fleet: physically still in China (54 rows).
UPDATE machines
SET status = 'Inactive', pod_location = 'China', updated_at = now()
WHERE official_name LIKE 'WH3\_%' ESCAPE '\' AND status = 'Warehouse';

-- 4) DIP warehouse: WH2_2006 (device 82160818, double door).
UPDATE machines
SET status = 'Inactive', pod_location = 'DIP', updated_at = now()
WHERE official_name = 'WH2_2006_0000_C0';

-- 5) Legacy bookkeeping ghosts (kept for history, excluded from counts).
UPDATE machines
SET status = 'Inactive', pod_location = 'Legacy', updated_at = now()
WHERE official_name IN
  ('ALHQ-1016-0000-O1','ALJ-1014-0200-O1_OLD','IRIS-1010-0000-O0_OLD',
   'JET-2001-3000-O1','WH2-1010-0000-L0','WH2-1023-0000-M0',
   'WH2-1024-0000-R0','WH2-2001-3000-O1','LLFP_2005_0000_L0','LLFP_2007_0000_R0');
