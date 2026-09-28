-- Loop 2026-09-25 F2 (CS HOLD feedback): populate machines.building_id for the named groups.
--
-- Root cause of the wrong cluster picks (GRIT-1022, ADDMIND-1007, AMZ-1029 all tagged cluster
-- despite machines.building_id being NULL for every machine): pick_machines_v12 (B2) derived a
-- fallback "building_code" from the official_name naming convention (first two digits of the
-- second hyphenated segment). Many unrelated machines share the placeholder "0000" segment (no
-- specific unit number), which collapsed to building_code "00" and silently clustered them
-- together even though they are not co-located. Confirmed live: IRIS-1070-0000-O1,
-- ADDMIND-1007-0000-W0, ACTIVATEMCC-1037-0000-L0 and MPMCC-1058-0000-R0 all produced "00".
--
-- Fix (this migration): populate the real machines.building_id column for the machine groups CS
-- named. pick_machines_v12 (next migration) switches from the naming-convention heuristic to
-- reading machines.building_id (via v_machine_priority.building_id, confirmed a direct passthrough
-- of machines.building_id) directly, so clustering only ever happens on a real, explicit building
-- assignment, never a coincidental name-parsing collision.
--
-- All 18 official_names checked live before writing anything; every one exists exactly as named
-- and every one's building_id is currently NULL (verified, not assumed).

SELECT set_config('app.mutation_reason',
  'loopv2 F2 (CS HOLD feedback): seed real building_id groups so pick_machines_v12 clusters only '
  || 'on an explicit building assignment, never a name-parsing coincidence. by=system', true);

UPDATE public.machines SET building_id = 'AMZ_B24'
 WHERE official_name IN ('AMZ-1068-2401-O1', 'AMZ-1046-2406-O1', 'AMZ-1057-2403-O1');

UPDATE public.machines SET building_id = 'AMZ_B30'
 WHERE official_name IN ('AMZ-1029-3003-O1', 'AMZ-1038-3001-O1');

UPDATE public.machines SET building_id = 'VML'
 WHERE official_name IN ('VML-1003-0400-O1', 'VML-1004-0500-O1');

UPDATE public.machines SET building_id = 'ALJLT'
 WHERE official_name IN ('ALJLT-1015-0100-B1', 'ALJLT-1015-0200-O1');

UPDATE public.machines SET building_id = 'MIRDIF_CC'
 WHERE official_name IN (
   'VOXMCC-1005-0201-B0', 'VOXMCC-1011-0101-B0', 'MPMCC-1054-0000-M0',
   'MPMCC-1058-0000-R0', 'IFLYMCC-1024-0000-W0', 'ACTIVATEMCC-1037-0000-L0'
 );

UPDATE public.machines SET building_id = 'WPP_TOWER'
 WHERE official_name IN ('WPP-1002-4300-O1', 'MINDSHARE-1009-4500-O1', 'WAVEMAKER-1006-4100-O1');
