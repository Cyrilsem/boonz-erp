-- ─── 1. CREATE venue_groups LOOKUP TABLE ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS venue_groups (
  code             TEXT PRIMARY KEY,
  display_name     TEXT NOT NULL,
  commercial_notes TEXT,
  active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE venue_groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "venue_groups_select_authenticated"
  ON venue_groups FOR SELECT TO authenticated USING (true);

CREATE POLICY "venue_groups_write_admins"
  ON venue_groups FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM user_profiles
      WHERE id = (SELECT auth.uid())
        AND role IN ('superadmin', 'operator_admin', 'manager')
    )
  );

-- ─── 2. SEED EXISTING + NEW (NOVO) ─────────────────────────────────────────────
INSERT INTO venue_groups (code, display_name) VALUES
  ('ADDMIND',     'Addmind'),
  ('VOX',         'VOX Cinemas'),
  ('VML',         'VML'),
  ('WPP',         'WPP'),
  ('OHMYDESK',    'OhmyDesk'),
  ('INDEPENDENT', 'Independent'),
  ('GRIT',        'GRIT'),
  ('NOVO',        'NOVO Cinemas')
ON CONFLICT (code) DO NOTHING;

-- ─── 3. REPLACE CHECK CONSTRAINT WITH FK ───────────────────────────────────────
-- The old check listed 7 hardcoded values. Now venue_group is governed by the
-- venue_groups table; new groups can be added without a code change.
ALTER TABLE machines DROP CONSTRAINT IF EXISTS machines_venue_group_check;

ALTER TABLE machines
  ADD CONSTRAINT machines_venue_group_fkey
  FOREIGN KEY (venue_group) REFERENCES venue_groups (code)
  ON UPDATE CASCADE
  ON DELETE RESTRICT;

-- ─── 4. updated_at trigger ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION venue_groups_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_venue_groups_updated_at ON venue_groups;
CREATE TRIGGER trg_venue_groups_updated_at
  BEFORE UPDATE ON venue_groups
  FOR EACH ROW EXECUTE FUNCTION venue_groups_set_updated_at();

COMMENT ON TABLE venue_groups IS
  'Lookup table for machine venue groups. Replaces the hardcoded machines_venue_group_check constraint. New groups can be added via the admin UI.';
