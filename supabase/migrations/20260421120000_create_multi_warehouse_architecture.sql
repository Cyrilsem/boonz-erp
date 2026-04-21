-- ================================================================
-- MULTI-WAREHOUSE ARCHITECTURE
-- Introduces a unified `warehouses` registry replacing the implicit
-- "central warehouse only" assumption throughout the schema.
--
-- Design decisions:
--   • All warehouses (central + staging) live in one table
--   • WH_MM + WH_MCC are ambient dark stores at VOX locations
--     (no cold storage — cold products always route via WH_CENTRAL)
--   • Each machine gets explicit primary + secondary warehouse FKs
--     (primary = staging room if VOX, central otherwise)
--   • refill_dispatching gets from/to warehouse FKs so leg type
--     is implicit from the relationship, not a string enum
--   • storage_temp_requirement on boonz_products controls whether
--     a product can be staged at an ambient location
--
-- Creates:
--   • warehouses          — unified registry (WH_CENTRAL, WH_MM, WH_MCC)
-- Alters:
--   • warehouse_inventory — adds warehouse_id FK (backfilled → WH_CENTRAL)
--   • machines            — adds primary_warehouse_id + secondary_warehouse_id
--   • refill_dispatching  — adds from_warehouse_id + to_warehouse_id
--   • boonz_products      — adds storage_temp_requirement (ambient/cold/frozen)
-- ================================================================

-- ── 1. WAREHOUSES REGISTRY ──────────────────────────────────────

CREATE TABLE warehouses (
  warehouse_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  TEXT        UNIQUE NOT NULL,
  display_name          TEXT        NOT NULL,
  warehouse_type        TEXT        NOT NULL CHECK (warehouse_type IN ('central', 'staging', 'dark_store')),
  venue_group           TEXT,                              -- NULL = central, 'VOX' = VOX staging rooms
  location_description  TEXT,
  allows_cold_storage   BOOLEAN     NOT NULL DEFAULT FALSE,
  allows_ambient        BOOLEAN     NOT NULL DEFAULT TRUE,
  is_active             BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE warehouses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "warehouses_select_authenticated"
  ON warehouses FOR SELECT TO authenticated USING (true);

CREATE POLICY "warehouses_write_admins"
  ON warehouses FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM user_profiles
      WHERE id = auth.uid()
        AND role IN ('superadmin', 'operator_admin', 'manager')
    )
  );

-- ── 2. SEED INITIAL WAREHOUSES ──────────────────────────────────

INSERT INTO warehouses (name, display_name, warehouse_type, venue_group, location_description, allows_cold_storage, allows_ambient)
VALUES
  (
    'WH_CENTRAL',
    'Central Warehouse',
    'central',
    NULL,
    'Main Boonz warehouse (WH3) — cold + ambient storage',
    TRUE,
    TRUE
  ),
  (
    'WH_MM',
    'VOX MM Staging',
    'staging',
    'VOX',
    'Ambient dark store at VOX MM location — no cold storage',
    FALSE,
    TRUE
  ),
  (
    'WH_MCC',
    'VOX MCC Staging',
    'staging',
    'VOX',
    'Ambient dark store at VOX MCC location — no cold storage',
    FALSE,
    TRUE
  );

-- ── 3. WAREHOUSE_INVENTORY: add warehouse_id FK ─────────────────
--
-- wh_location remains as the internal bin/shelf location WITHIN
-- a warehouse (e.g. 'A-03'). warehouse_id tells you WHICH warehouse.

ALTER TABLE warehouse_inventory
  ADD COLUMN warehouse_id UUID REFERENCES warehouses(warehouse_id);

-- All existing rows are central warehouse stock
UPDATE warehouse_inventory
  SET warehouse_id = (SELECT warehouse_id FROM warehouses WHERE name = 'WH_CENTRAL');

-- ── 4. MACHINES: primary + secondary warehouse assignments ───────
--
-- primary_warehouse_id:   where the driver picks stock for this machine
--                         (staging room for VOX, central for everyone else)
-- secondary_warehouse_id: fallback when primary is out of stock,
--                         or for cold products that can't be staged
--                         (always WH_CENTRAL for VOX machines, NULL otherwise)

ALTER TABLE machines
  ADD COLUMN primary_warehouse_id   UUID REFERENCES warehouses(warehouse_id),
  ADD COLUMN secondary_warehouse_id UUID REFERENCES warehouses(warehouse_id);

-- VOXMM machines → primary WH_MM, fallback WH_CENTRAL
UPDATE machines
  SET primary_warehouse_id   = (SELECT warehouse_id FROM warehouses WHERE name = 'WH_MM'),
      secondary_warehouse_id = (SELECT warehouse_id FROM warehouses WHERE name = 'WH_CENTRAL')
  WHERE official_name LIKE 'VOXMM-%';

-- VOXMCC + ACTIVATEMCC + MPMCC → primary WH_MCC, fallback WH_CENTRAL
UPDATE machines
  SET primary_warehouse_id   = (SELECT warehouse_id FROM warehouses WHERE name = 'WH_MCC'),
      secondary_warehouse_id = (SELECT warehouse_id FROM warehouses WHERE name = 'WH_CENTRAL')
  WHERE official_name LIKE 'VOXMCC-%'
     OR official_name LIKE 'ACTIVATEMCC-%'
     OR official_name LIKE 'MPMCC%';

-- All remaining machines → primary WH_CENTRAL, no secondary
UPDATE machines
  SET primary_warehouse_id = (SELECT warehouse_id FROM warehouses WHERE name = 'WH_CENTRAL')
  WHERE primary_warehouse_id IS NULL;

-- ── 5. REFILL_DISPATCHING: source + destination warehouse ────────
--
-- from_warehouse_id: where stock is physically pulled from
-- to_warehouse_id:   populated only for warehouse-to-warehouse
--                    Leg 1 transfers (Central → Staging).
--                    NULL on all normal pod dispatch rows (use machine_id instead).
--
-- Reading the leg type:
--   from=WH_CENTRAL, to_warehouse_id IS NOT NULL → Leg 1 (staging replenishment)
--   from=WH_MM/WH_MCC, machine_id IS NOT NULL    → Leg 2 (local pod fill)
--   from=WH_CENTRAL, machine_id IS NOT NULL       → Direct (cold product bypass)

ALTER TABLE refill_dispatching
  ADD COLUMN from_warehouse_id UUID REFERENCES warehouses(warehouse_id),
  ADD COLUMN to_warehouse_id   UUID REFERENCES warehouses(warehouse_id);

-- All existing dispatch rows came from central warehouse
UPDATE refill_dispatching
  SET from_warehouse_id = (SELECT warehouse_id FROM warehouses WHERE name = 'WH_CENTRAL');

-- ── 6. BOONZ_PRODUCTS: storage temperature requirement ──────────
--
-- Controls whether a product can be held in ambient staging rooms.
--   ambient → eligible for WH_MM / WH_MCC staging
--   cold    → must route WH_CENTRAL → pod directly (requires refrigeration)
--   frozen  → must route WH_CENTRAL → pod directly (requires freezer)
--
-- Default is 'ambient' (safe for most products). Update cold products
-- (e.g. Activia, fresh dairy) manually after migration.

ALTER TABLE boonz_products
  ADD COLUMN storage_temp_requirement TEXT NOT NULL DEFAULT 'ambient'
    CHECK (storage_temp_requirement IN ('ambient', 'cold', 'frozen'));
