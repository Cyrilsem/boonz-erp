-- CS-06: Backfill machines.building_id for 22 eligible machines (9 buildings)
BEGIN;

UPDATE machines SET building_id='DUBAI_HARBOUR_MARSA' WHERE official_name IN ('ADDMIND-1007-0000-W0','USH-1008-0000-W1');
UPDATE machines SET building_id='JLT' WHERE official_name IN ('ALJLT-1015-0100-B1','ALJLT-1014-0200-O1','NOOK-1019-0200-B1');
UPDATE machines SET building_id='MEDIA_CITY' WHERE official_name IN ('HUAWEI-2003-0000-B1','MC-2004-0100-O1','VML-1003-0400-O1','VML-1004-0500-O1','WAVEMAKER-1006-4100-O1','WPP-1002-4300-O1','MINDSHARE-1009-4500-O1');
UPDATE machines SET building_id='BUSINESS_BAY' WHERE official_name='OMDBB-1020-0P00-O1';
UPDATE machines SET building_id='CITY_WALK_DOWNTOWN' WHERE official_name='OMDCW-1021-0100-W0';
UPDATE machines SET building_id='JUMEIRAH' WHERE official_name='GRIT-1022-0100-W0';
UPDATE machines SET building_id='MIRDIF_MAF' WHERE official_name IN ('VOXMCC-1009-0201-B0','VOXMCC-1011-0101-B0','VOXMCC-1012-0100-V0','VOXMCC-1017-0200-V0');
UPDATE machines SET building_id='VOX_MERCATO' WHERE official_name IN ('VOXMM-1009-0100-V0','VOXMM-1013-0101-B0');
UPDATE machines SET building_id='DIFC' WHERE official_name='JET-1016-0000-O1';

UPDATE machines SET pod_address='Mirdif MAF' WHERE official_name IN ('VOXMCC-1011-0101-B0','VOXMCC-1012-0100-V0','VOXMCC-1017-0200-V0') AND pod_address IS NULL;
UPDATE machines SET pod_address='DIFC' WHERE official_name='JET-1016-0000-O1' AND pod_address IS NULL;

DO $$ DECLARE n int; BEGIN
  SELECT COUNT(*) INTO n FROM machines WHERE adyen_status='Online today' AND repurposed_at IS NULL AND building_id IS NULL;
  IF n>0 THEN RAISE EXCEPTION 'CS-06 incomplete: % eligible machines still NULL', n; END IF;
END $$;

COMMIT;
