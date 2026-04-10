-- CC-02b retry: Pattern-based backfill of machines.venue_group from official_name prefixes.
-- Runs after 107600 (ADD COLUMN). All rows start at DEFAULT 'INDEPENDENT'.
UPDATE public.machines
SET venue_group = CASE
  -- ADDMIND group
  WHEN official_name LIKE 'ADDMIND%' THEN 'ADDMIND'
  WHEN official_name LIKE 'USH%'     THEN 'ADDMIND'
  WHEN official_name LIKE 'IRIS%'    THEN 'ADDMIND'

  -- VOX group (any <BRAND>MCC pattern where BRAND is a VOX family member)
  WHEN official_name LIKE 'VOXMCC%'      THEN 'VOX'
  WHEN official_name LIKE 'VOXMM%'       THEN 'VOX'
  WHEN official_name LIKE 'ACTIVATEMCC%' THEN 'VOX'
  WHEN official_name LIKE 'MPMCC%'       THEN 'VOX'
  WHEN official_name LIKE 'IFLYMCC%'     THEN 'VOX'
  WHEN official_name LIKE 'SKYMCC%'      THEN 'VOX'

  -- VML group
  WHEN official_name LIKE 'VML%' THEN 'VML'

  -- WPP family group
  WHEN official_name LIKE 'WPP%'        THEN 'WPP'
  WHEN official_name LIKE 'MINDSHARE%'  THEN 'WPP'
  WHEN official_name LIKE 'WAVEMAKER%'  THEN 'WPP'

  -- OHMYDESK family group
  WHEN official_name LIKE 'OMDBB%' THEN 'OHMYDESK'
  WHEN official_name LIKE 'OMDCW%' THEN 'OHMYDESK'

  ELSE 'INDEPENDENT'
END;
