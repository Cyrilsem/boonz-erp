-- PRD-120 follow-up F1: v_pod_inventory_latest can return an Inactive row as "latest"
-- within a (machine_id, shelf_id, boonz_product_id, expiration_date) grain when it shares
-- an identical snapshot_at with the grain's Active row (the old receive_dispatch_line merge
-- pattern stamped the archived row's snapshot_at to the same now() as the new Active
-- insert). DISTINCT ON's tiebreak by snapshot_at alone then resolves arbitrarily by scan
-- order, not by status.
--
-- Real incident: machine f1a528fb-15e8-4f20-b4e2-ebb2e6852198 (AMZ-1029-3003-O1), product
-- e4ca510b-1515-4629-bcf1-0d71154b1a3f (Freakin Protein Balls - Carmel Crunch 3P), shelf
-- A04 (d9fe3709-318d-4107-85b0-c7fdac5fd565): an Active 9-unit row and an Inactive 8-unit
-- row both carry snapshot_at 2026-08-25 08:22:27.600126+00. The view returned the Inactive
-- row, so repair_remove_leg_shelf_lot (which additionally filters status='Active' on the
-- view's output) raised "no Active pod lot found ... nothing to repair against" on a lane
-- that has one, blocking dispatch 45d8c556-1471-44e3-97c7-3e616bda4f20.
--
-- Fix: order by (status = 'Active') DESC before recency, so the grain's Active row always
-- wins (idx_pod_inv_active_shelf_expiry guarantees at most one Active row per grain).
-- Recency tiebreak switched from snapshot_at to created_at: snapshot_at is mutated by the
-- archive-time UPDATE (that's the root cause of the tie), created_at is insert-only and
-- immutable. Dara-reviewed, Cody-approved (Articles 1, 12, 16 - no new write path, forward-
-- only CREATE OR REPLACE, same canonical object unchanged in shape).
--
-- Verified in a rolled-back transaction against the live reproduction case above (now
-- returns the Active/9-unit row) before this real apply.

CREATE OR REPLACE VIEW public.v_pod_inventory_latest AS
SELECT DISTINCT ON (machine_id, shelf_id, boonz_product_id, expiration_date)
  machine_id, shelf_id, boonz_product_id, current_stock, expiration_date, batch_id, status, snapshot_at, pod_inventory_id
FROM public.pod_inventory pi
ORDER BY machine_id, shelf_id, boonz_product_id, expiration_date,
  (status = 'Active') DESC, created_at DESC;

-- Fixture (temp table, dropped at session end, no effect on real data): a machine+product+
-- shelf+expiry grain with an Active row that has an OLDER created_at/snapshot_at than a
-- newer Inactive row must still resolve to the Active row.
DO $fx$
DECLARE v_active_wins boolean;
BEGIN
  CREATE TEMP TABLE fx_pod_f1 (LIKE public.pod_inventory INCLUDING ALL) ON COMMIT DROP;
  INSERT INTO fx_pod_f1 (pod_inventory_id, machine_id, shelf_id, boonz_product_id, snapshot_date,
    current_stock, expiration_date, batch_id, status, created_at, snapshot_at)
  VALUES
    (gen_random_uuid(), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'cccccccc-cccc-cccc-cccc-cccccccccccc', '2026-01-01', 5, '2027-01-01', 'FX-ACTIVE', 'Active',
     '2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00'),
    (gen_random_uuid(), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'cccccccc-cccc-cccc-cccc-cccccccccccc', '2026-01-02', 3, '2027-01-01', 'FX-INACTIVE', 'Inactive',
     '2026-01-02 00:00:00+00', '2026-01-02 00:00:00+00');

  SELECT (status = 'Active') INTO v_active_wins
  FROM (SELECT DISTINCT ON (machine_id, shelf_id, boonz_product_id, expiration_date)
    machine_id, shelf_id, boonz_product_id, status
    FROM fx_pod_f1
    ORDER BY machine_id, shelf_id, boonz_product_id, expiration_date, (status='Active') DESC, created_at DESC) s;

  IF NOT v_active_wins THEN
    RAISE EXCEPTION 'PRD120-F1 FIXTURE FAILED: Active row did not win despite older created_at/snapshot_at';
  END IF;
  RAISE NOTICE 'PRD120-F1 FIXTURE PASSED: Active wins over newer Inactive row';
END $fx$;
