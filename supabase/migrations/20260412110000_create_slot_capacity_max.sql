-- Migration: create slot_capacity_max table
-- CC-20-CC2 step 1 of 2
-- Sparse override layer for Engine B capacity ceiling.
-- Rows only exist where operator wants to cap below Weimi-reported max_stock.
-- Empty at creation — populated manually over time.

CREATE TABLE slot_capacity_max (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id        uuid NOT NULL REFERENCES machines(machine_id) ON DELETE CASCADE,
  aisle_code        text NOT NULL,
  override_max_stock integer NOT NULL CHECK (override_max_stock > 0),
  reason            text,
  created_at        timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now(),
  UNIQUE (machine_id, aisle_code)
);

-- RLS
ALTER TABLE slot_capacity_max ENABLE ROW LEVEL SECURITY;

CREATE POLICY slot_capacity_max_select
  ON slot_capacity_max FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY slot_capacity_max_all_admin
  ON slot_capacity_max FOR ALL
  USING ((SELECT auth.uid()) IN (
    SELECT id FROM auth.users
    WHERE raw_user_meta_data->>'role' = 'operator_admin'
  ));

-- updated_at trigger — using project-standard set_updated_at()
CREATE TRIGGER set_slot_capacity_max_updated_at
  BEFORE UPDATE ON slot_capacity_max
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
