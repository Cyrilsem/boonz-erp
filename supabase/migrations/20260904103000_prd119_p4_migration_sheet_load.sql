-- PRD-119 P4: one-time load of the returns Google Sheet (id
-- 1Xlxh0CkNb3lbowF2P8vel8QA4zpeHSqRS1sKUq3Lr_o, read live via Google Drive MCP —
-- no CSV fallback needed) into disposition_events, source='migration_sheet'.
--
-- Sheet had grown to 113 rows / 365 units by load time (vs the PRD's 02-Sep
-- snapshot of 104/340 — natural drift, loaded as-found rather than the stale
-- snapshot number).
--
-- Product-name resolution: exact match, then normalized (punctuation/case-
-- insensitive) match, then a hand-verified alias map — every alias checked
-- against the live catalog before being added, never guessed on an ambiguous
-- multi-variant product. 99/113 rows (315/365 units) resolved and loaded.
--
-- 14 rows (50 units) deliberately NOT loaded, flagged for CS:
--   - Genuinely ambiguous (2-3 catalog variants, sheet gives no way to pick):
--     Caprice x2, "7 days" x1, Extra Gum x1, Yan Yan x1, Sunblast x1.
--   - Absent from the current catalog entirely: Vitamin Well - Well Care x2,
--     Be kind bar - peanut butter x1, Be kind bar - Dark chocolate x1,
--     Barebells - Carmel Cashew x1.
--   - One row with a blank product name (qty 7, exp 16 Jul 2026).
--   - YoPro Vanilla / YoPro chocolate x2 — the PRD's OWN §6 text already names
--     this exact "YoPro Vanilla/Strawberry mismatch" as a flag-for-CS item.
--
-- State mapping: sheet status='Removed'/'Damage' + "Updated in system-
-- Removed"='Yes' -> state='waste' (already dealt with in the old manual
-- process), disposal_code='Returning to supplier' if the sheet's Replacement
-- column says so, else 'Waste'. "Updated in system-Removed"='No' (2 rows, 4
-- units) -> state='removed_at_machine' (genuinely still open/unreconciled),
-- left for a human to resolve rather than silently marked done.
--
-- Verified live in a rolled-back transaction before this real apply: 99 rows
-- load correctly (97 waste/311 units, 2 removed_at_machine/4 units).
--
-- Cody: approve, Articles 1/7/12 — one-time historical backfill via a
-- privileged migration role (not `authenticated`, so the S-308 REVOKE this
-- table carries is not being bypassed), additive only, idempotency guarded.
DO $mig$ BEGIN
  IF EXISTS (SELECT 1 FROM public.disposition_events WHERE source='migration_sheet') THEN
    RAISE EXCEPTION 'migration_sheet rows already loaded — refusing to double-load';
  END IF;
END $mig$;

CREATE TEMP TABLE _sheet_raw (row_no serial, product_name text, qty numeric, expiry_date date, status text, updated_removed text, replacement text, return_from text);

INSERT INTO _sheet_raw (product_name, qty, expiry_date, status, updated_removed, replacement, return_from) VALUES
('Almarai Juice - Orange',6,'2026-05-19','Removed','Yes',NULL,NULL),
('Almarai Juice - Pomegranate',9,'2026-06-12','Removed','Yes',NULL,NULL),
('Arla Pro - Caramel Pudding',3,'2026-07-04','Removed','Yes',NULL,NULL),
(NULL,7,'2026-07-16','Removed','Yes',NULL,NULL),
('Pepsi - Black',1,'2026-05-17','Removed','Yes',NULL,NULL),
('Santiveri - Cran Berry',2,'2026-06-05','Removed','Yes',NULL,NULL),
('Santiveri - Double Chocolate',1,'2026-06-06','Removed','Yes',NULL,NULL),
('Santiveri - Coco Quinoa',2,'2026-06-12','Removed','Yes',NULL,NULL),
('Natural Fruit & Veggie - Regular',4,'2026-04-30','Removed','Yes',NULL,NULL),
('Nescafe - Mocha Iced Coffee',1,'2026-04-24','Removed','Yes',NULL,NULL),
('Nescafe - Mocha Iced Coffee',6,'2026-05-28','Removed','Yes',NULL,NULL),
('Caprice',6,'2026-07-17','Removed','Yes',NULL,NULL),
('Caprice',1,'2026-05-12','Removed','Yes',NULL,NULL),
('Sunblast',10,'2026-04-21','Removed','Yes',NULL,NULL),
('Evian Sparkling Water',5,'2026-06-04','Removed','Yes',NULL,NULL),
('7 Days - Hazelnut',5,'2026-04-27','Removed','Yes',NULL,NULL),
('Bounty - Regular',9,'2026-05-10','Removed','Yes',NULL,NULL),
('Bounty - Regular',6,'2026-08-02','Removed','Yes',NULL,NULL),
('Bounty - Regular',13,'2026-04-26','Removed','Yes',NULL,NULL),
('Bounty - Regular',5,'2026-03-22','Removed','Yes',NULL,NULL),
('Bounty - Regular',4,'2026-08-01','Removed','Yes',NULL,NULL),
('Lays Chips - Chili',1,'2026-05-24','Removed','Yes',NULL,NULL),
('Lays Chips - Tomato & Ketchup',1,'2026-05-12','Removed','Yes',NULL,NULL),
('Freakin Protein Balls - Coconut 4P',1,'2026-04-25','Removed','Yes',NULL,NULL),
('Mountain Dew - Diet',2,'2026-06-02','Removed','Yes',NULL,NULL),
('Coca Cola - Zero',1,'2026-08-24','Removed','Yes',NULL,NULL),
('Yumearth Gummy Bears',4,'2026-05-31','Removed','Yes',NULL,NULL),
('Mcvities  white Nibbles',1,'2026-04-16','Removed','Yes',NULL,NULL),
('M&M choclate Nut',3,'2026-06-12','Removed','Yes',NULL,NULL),
('M&M Chocolate Bags',1,'2026-06-28','Removed','Yes',NULL,NULL),
('7 days',4,'2026-04-26','Removed','Yes',NULL,NULL),
('Green Olives - Krambals',2,'2026-07-10','Removed','Yes','Return to supplier',NULL),
('Kinder Delice',1,'2026-06-03','Removed','Yes',NULL,NULL),
('Barebells Cookies and Cream',1,'2026-06-23','Removed','Yes',NULL,NULL),
('Dubai Popcorn  - Salted',1,'2026-06-29','Removed','Yes',NULL,NULL),
('Kinder Delice',2,'2026-06-29','Removed','Yes',NULL,NULL),
('M&M Chocolate Nut',3,'2026-07-12','Removed','Yes',NULL,NULL),
('Coca Cola  Regular',2,'2026-07-02','Removed','Yes',NULL,NULL),
('Kinder Delice',1,'2026-07-17','Removed','Yes',NULL,NULL),
('Mars',1,'2026-07-20','Removed','Yes',NULL,NULL),
('Mountain Dew - Regular',2,'2026-07-27','Removed','Yes',NULL,NULL),
('Vitamin Well - Upgrade',5,'2026-05-31','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Upgrade',1,'2026-05-17','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Upgrade',6,'2026-06-21','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Upgrade',6,'2026-07-05','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Reload',2,'2026-05-17','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Reload',6,'2026-05-31','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Reload',3,'2026-06-14','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Reload',2,'2026-08-23','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Reload',1,'2026-08-30','Removed','No','Return to supplier','Return from MC'),
('Vitamin Well - Reload',4,'2026-06-28','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Hydrate',3,'2026-05-10','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Hydrate',2,'2026-06-21','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Hydrate',3,'2026-06-28','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Well Care',3,'2026-05-31','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Well Care',3,'2026-06-07','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Antioxidant',12,'2026-06-07','Removed','Yes','Return to supplier',NULL),
('Vitamin Well - Antioxidant',1,'2026-06-28','Removed','Yes',NULL,NULL),
('Be kind Cluster - Dark Chocolate',1,'2026-06-09','Removed','Yes',NULL,NULL),
('M&M Chocolate Nut',3,'2026-07-12','Removed','Yes',NULL,NULL),
('Extra Gum',6,'2026-06-16','Removed','Yes',NULL,NULL),
('Coffee Joy',2,'2026-07-21','Removed','Yes',NULL,NULL),
('M&M Chocolate Nut',8,'2026-07-12','Removed','Yes',NULL,NULL),
('Pepsi - Black',2,'2026-07-17','Removed','Yes',NULL,NULL),
('Starbucks Double Shot - Diet',2,'2026-08-14','Removed','Yes',NULL,NULL),
('Mountain Dew - Regular',5,'2026-07-27','Removed','Yes',NULL,NULL),
('Yan Yan',2,'2026-08-11','Removed','Yes',NULL,NULL),
('Starbucks - Double shot',5,'2026-07-16','Removed','Yes',NULL,NULL),
('Starbucks - Double shot',14,'2026-08-14','Removed','Yes',NULL,NULL),
('Starbucks - Double shot',2,'2026-05-22','Removed','Yes',NULL,NULL),
('Benlain Chips - Sour Cream',1,'2026-08-12','Removed','Yes',NULL,NULL),
('Oreo - Regular',2,'2026-06-01','Removed','Yes',NULL,NULL),
('Coca- Cola Zero',1,'2026-08-24','Removed','Yes',NULL,NULL),
('Be kind Cluster- Dark Choclate',2,'2026-08-17','Removed','Yes',NULL,NULL),
('Be kind Cluster - Hazelnut',3,'2026-08-19','Removed','Yes',NULL,NULL),
('Mcvities Nibbles - Double chocolate',5,'2026-08-19','Removed','Yes',NULL,NULL),
('McVitie''s Nibbles - Dark chocolate',1,'2026-08-19','Removed','Yes',NULL,NULL),
('McVitie''s Nibbles - Choco Caramel',2,'2026-08-12','Removed','Yes',NULL,NULL),
('Benlain Chips - Sea salted',2,'2026-08-18','Removed','Yes',NULL,NULL),
('Ulker -sesame Biscuits',3,'2026-08-20','Removed','Yes',NULL,NULL),
('G&H pop Chips Sweet and salty  black pepper',3,'2026-08-26','Removed','Yes','Return to supplier',NULL),
('G&H pop Chips Sweet and salty',5,'2026-08-20','Removed','Yes','Return to supplier',NULL),
('G&H pop Chips Sweet bbq',1,'2026-08-21','Removed','Yes','Return to supplier',NULL),
('Perrier - Grapefruit',1,'2026-06-03','Removed','Yes',NULL,NULL),
('Sunbite - Cheese',1,'2026-08-25','Removed','Yes',NULL,NULL),
('Vitamin Well - Reload',2,'2026-08-23','Removed','Yes',NULL,NULL),
('Pepsi - Black',1,'2026-12-11','Damage','Yes',NULL,NULL),
('Pepsi - Black',1,'2027-01-01','Damage','Yes',NULL,NULL),
('Activia - Honey',2,'2026-08-06','Removed','Yes','Return to supplier- Replacement done',NULL),
('Activia - Honey',2,'2026-08-21','Removed','Yes','Return to supplier',NULL),
('Activia - Honey',8,'2026-08-21','Removed','Yes','Return to supplier',NULL),
('Activia - Honey',1,'2026-08-22','Removed','Yes',NULL,NULL),
('Activia - Honey',1,'2026-08-15','Removed','Yes','Return to supplier',NULL),
('Activia - Strawbery',5,'2026-08-10','Removed','Yes','Return to supplier',NULL),
('Activia - Strawbery',2,'2026-08-22','Removed','Yes','Return to supplier',NULL),
('Activia - Strawbery',2,'2026-08-31','Removed','Yes','Return to supplier',NULL),
('Activia - Strawbery',3,'2026-08-31','Removed','No','Return to supplier','Return from Mc'),
('Activia - Strawbery',1,'2026-08-19','Removed','Yes','Return to supplier',NULL),
('Activia - Strawbery',1,'2026-08-31','Removed','Yes','Return to supplier','Return from Nissan'),
('Yo pro chocolate',1,'2026-06-16','Removed','Yes','Return to supplier',NULL),
('Pepsi - Black - 250 ML',12,'2026-04-10','Removed','Yes',NULL,NULL),
('Ice Tea - Peach',1,'2026-07-16','Removed','Yes',NULL,NULL),
('Yo pro - Vanilla',1,'2026-08-31','Removed','No','Return to supplier','Return from Mc'),
('Be kind bar - peanut butter - 50g',4,'2026-09-04','Removed','No',NULL,'Return from Mc'),
('Be kind bar - Dark chocolate - 40 g',1,'2026-09-02','Removed','No',NULL,'Return from Mc'),
('Nescafe - Mocha Iced Coffee',4,'2026-09-05','Removed','Yes',NULL,NULL),
('Nescafe - Cappucino Iced Coffee',12,'2026-09-05','Removed','Yes',NULL,NULL),
('NRJ - Trail Mix',2,'2026-09-05','Removed','Yes',NULL,NULL),
('NRJ - Roasted & Salted',2,'2026-09-05','Removed','Yes',NULL,NULL),
('Sunbities - Olives and Oregano',1,'2026-08-29','Removed','Yes',NULL,'Removed From Nissan'),
('Vitamin well - Zero Lemon',1,'2026-09-06','Removed','Yes',NULL,NULL),
('Barebells - Carmel Cashew',1,'2026-06-27','Removed','No',NULL,'Removed From Nook'),
('Sunbities - Olive and Oregano',1,'2026-09-05','Removed','Yes',NULL,'Removed From Nissan');

CREATE OR REPLACE FUNCTION pg_temp.norm(t text) RETURNS text AS $$
  SELECT regexp_replace(lower(trim(t)), '[^a-z0-9]', '', 'g');
$$ LANGUAGE sql IMMUTABLE;

CREATE TEMP TABLE _alias (sheet_name text, canonical_name text);
INSERT INTO _alias VALUES
('Activia - Honey','Activia Mix & Go - Greek Yogurt Honey & Oats'),
('Activia - Strawbery','Activia Mix & Go - Greek Yogurt Strawberries'),
('Be kind Cluster- Dark Choclate','Be-kind Cluster - Dark Chocolate'),
('Benlain Chips - Sea salted','Benlian Chips - Sea Salted'),
('Benlain Chips - Sour Cream','Benlian Chips - Sour Cream'),
('Coffee Joy','Coffee Joy - Coffee'),
('Evian Sparkling Water','Evian Sparkling - Regular'),
('G&H pop Chips Sweet and salty','G&H Popped Chips - Sweet And Salty'),
('G&H pop Chips Sweet and salty  black pepper','G&H Popped Protein - Salt & Black Pepper'),
('G&H pop Chips Sweet bbq','G&H Popped Chips - Sweet BBQ'),
('Green Olives - Krambals','Krambals - Green Olives & Sea Salt'),
('Kinder Delice','Kinder Delice - Cake'),
('M&M choclate Nut','M&M - Chocolate Nuts'),
('M&M Chocolate Bags','M&M Chocolate Bag - Regular Large'),
('M&M Chocolate Nut','M&M - Chocolate Nuts'),
('Mars','Mars - Regular'),
('McVitie''s Nibbles - Choco Caramel','McVities Digestive Nibbles - Choco Caramel'),
('McVitie''s Nibbles - Dark chocolate','McVities Digestive Nibbles - Dark Chocolate'),
('Mcvities  white Nibbles','McVities Digestive Nibbles - White Chocolate'),
('Mcvities Nibbles - Double chocolate','McVities Digestive Nibbles - Double Chocolate'),
('NRJ - Roasted & Salted','NRJ Nut - Roasted & Salted'),
('NRJ - Trail Mix','NRJ Nut - Trail Mix'),
('Oreo - Regular','Oreo Cookie - Regular'),
('Pepsi - Black - 250 ML','Pepsi - Black'),
('Perrier - Grapefruit','Perrier - Flavored Grapefruit'),
('Starbucks - Double shot','Starbucks - Double Shot Espresso'),
('Starbucks Double Shot - Diet','Starbucks - Double Shot Espresso Diet'),
('Sunbite - Cheese','Sunbites - Cheese'),
('Sunbities - Olive and Oregano','Sunbites - Olive And Oregano'),
('Sunbities - Olives and Oregano','Sunbites - Olive And Oregano'),
('Ulker -sesame Biscuits','Ulker - Sesame'),
('Yumearth Gummy Bears','Yumearth Gummy Bears - Regular');

CREATE TEMP TABLE _resolved AS
SELECT sr.*,
  COALESCE(bp1.product_id, bp2.product_id, bp3.product_id) AS boonz_product_id,
  COALESCE(bp1.avg_cost, bp2.avg_cost, bp3.avg_cost) AS unit_cost
FROM _sheet_raw sr
LEFT JOIN boonz_products bp1 ON lower(trim(bp1.boonz_product_name)) = lower(trim(sr.product_name))
LEFT JOIN boonz_products bp2 ON pg_temp.norm(bp2.boonz_product_name) = pg_temp.norm(sr.product_name)
LEFT JOIN _alias a ON a.sheet_name = sr.product_name
LEFT JOIN boonz_products bp3 ON bp3.boonz_product_name = a.canonical_name;

INSERT INTO public.disposition_events
  (source, boonz_product_id, expiration_date, qty, state, disposal_code, value_aed, reason, created_at)
SELECT
  'migration_sheet',
  r.boonz_product_id,
  r.expiry_date,
  r.qty,
  CASE WHEN r.updated_removed = 'No' THEN 'removed_at_machine' ELSE 'waste' END,
  CASE WHEN r.updated_removed = 'No' THEN NULL
       WHEN r.replacement ILIKE '%return to supplier%' THEN 'Returning to supplier'
       ELSE 'Waste' END,
  r.unit_cost * r.qty,
  concat_ws('; ', 'migrated from returns sheet', 'sheet status='||r.status,
    CASE WHEN r.return_from IS NOT NULL THEN 'origin: '||r.return_from END,
    CASE WHEN r.replacement IS NOT NULL THEN 'replacement: '||r.replacement END),
  now()
FROM _resolved r
WHERE r.boonz_product_id IS NOT NULL;
