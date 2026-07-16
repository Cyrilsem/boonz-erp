-- MIRROR of 2026-07-15 chat-applied prod change (do NOT re-apply; idempotent).
-- 10 LevelUp partner products PD168-PD177: boonz (LevelUp - X, sourcing_channel 'LevelUp Kitchen',
-- avg_cost NULL by design) + pod (pico/count) + global mapping (machine_id NULL, venue_team) + weimi alias.
-- UUIDs are the live prod IDs. NOTE (drift, logged in DECISIONS.md): the earlier 2026-07-10 LevelUp
-- batch PD148-PD162 (14 'Assorted'/fresh products) is NOT yet mirrored anywhere - out of this goal's scope.

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('dc368bf2-3da1-442e-82af-f2bb30cc9c96', 'LevelUp - Yubi Protein Bar', 'Protein & Health Bars', 'bar_standard', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('1eaa0773-ddda-411a-9ba6-3d2d3e3c6584', 'PD168', 'Yubi Protein Bar', 'Protein & Health Bars', 'pico', 'count', 18.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('605a3d7b-ddd8-492d-a462-fd3cbaaab509', '1eaa0773-ddda-411a-9ba6-3d2d3e3c6584', 'dc368bf2-3da1-442e-82af-f2bb30cc9c96', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Yubi Protein Bar', '1eaa0773-ddda-411a-9ba6-3d2d3e3c6584')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('eed0b4aa-7f10-4cd2-b6be-530c1049e800', 'LevelUp - Barakat Health Shots', 'Vitamin & Health Drinks', 'bottle_shot', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('eadbf98c-2b5d-47b1-8fe8-aa581f032e61', 'PD169', 'Barakat Health Shots', 'Vitamin & Health Drinks', 'pico', 'count', 14.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('b8d4c7e4-e7ae-45be-ad92-b4eacf89eac3', 'eadbf98c-2b5d-47b1-8fe8-aa581f032e61', 'eed0b4aa-7f10-4cd2-b6be-530c1049e800', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Barakat Health Shots', 'eadbf98c-2b5d-47b1-8fe8-aa581f032e61')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('7e7cddae-36bf-4c88-93bf-4b0ba025d95a', 'LevelUp - Barebell Protein Shake', 'Protein Milk', 'bottle_330', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('4056996c-14d8-4b83-a00e-77152c733dc4', 'PD170', 'Barebell Protein Shake', 'Protein Milk', 'pico', 'count', 20.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('6e32f271-a453-4824-83c2-79b47c3bae58', '4056996c-14d8-4b83-a00e-77152c733dc4', '7e7cddae-36bf-4c88-93bf-4b0ba025d95a', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Barebell Protein Shake', '4056996c-14d8-4b83-a00e-77152c733dc4')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('4d3e18ea-01e0-4c16-a0b9-6cda389a350e', 'LevelUp - Kindlyfe', 'Chocolate Bar', 'bar_standard', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('82489578-63af-4886-95ed-c15658e1b12d', 'PD171', 'Kindlyfe', 'Chocolate Bar', 'pico', 'count', 15.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('9dbdf16f-2441-4949-92aa-3fd08ed10248', '82489578-63af-4886-95ed-c15658e1b12d', '4d3e18ea-01e0-4c16-a0b9-6cda389a350e', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Kindlyfe', '82489578-63af-4886-95ed-c15658e1b12d')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('b5221a5f-30ad-4f8e-8c44-af0a92c020a6', 'LevelUp - Bliss Veggie Chips', 'Chips & Crisps', 'bag_snack', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('7651ffa5-d6af-4a52-b733-51c80a155861', 'PD172', 'Bliss Veggie Chips', 'Chips & Crisps', 'pico', 'count', 10.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('039ac3d6-075f-4023-b243-c9fc428f2711', '7651ffa5-d6af-4a52-b733-51c80a155861', 'b5221a5f-30ad-4f8e-8c44-af0a92c020a6', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Bliss Veggie Chips', '7651ffa5-d6af-4a52-b733-51c80a155861')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('b7325d1a-5903-4f19-861d-5bcbcdb6159e', 'LevelUp - Fresh Apple', 'Fresh Fruit', 'other', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('69b72d87-7678-42d9-a8b4-b85ba784858f', 'PD173', 'Fresh Apple', 'Fresh Fruit', 'pico', 'count', 5.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('e4a9b01b-a3fc-4705-83a6-483d9f805238', '69b72d87-7678-42d9-a8b4-b85ba784858f', 'b7325d1a-5903-4f19-861d-5bcbcdb6159e', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Apple', '69b72d87-7678-42d9-a8b4-b85ba784858f')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('4376b317-653f-4de2-a47d-df8b356e1772', 'LevelUp - Just Chips', 'Chips & Crisps', 'bag_snack', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('24a4d129-bf93-4782-847b-cbf9a9a50a54', 'PD174', 'Just Chips', 'Chips & Crisps', 'pico', 'count', 10.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('ce551aca-8e4b-47e1-baef-67820b2dee85', '24a4d129-bf93-4782-847b-cbf9a9a50a54', '4376b317-653f-4de2-a47d-df8b356e1772', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Just Chips', '24a4d129-bf93-4782-847b-cbf9a9a50a54')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('7355e278-f6aa-4ac0-a9b8-2258bcf3b95f', 'LevelUp - Al Ain Water 1.5L', 'Water', 'bottle_large', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('6b9de2a2-6a05-4d08-a249-510d73869dec', 'PD175', 'Al Ain Water 1.5L', 'Water', 'pico', 'count', 7.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('46ce0544-8cdf-483a-ab57-131fa6727e68', '6b9de2a2-6a05-4d08-a249-510d73869dec', '7355e278-f6aa-4ac0-a9b8-2258bcf3b95f', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Al Ain Water 1.5L', '6b9de2a2-6a05-4d08-a249-510d73869dec')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('5465d9a4-3d1b-4ebe-bd68-cdb5e523670e', 'LevelUp - Choco Orange Cake', 'Cakes', 'cake_wrapped', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('9ba40daa-a15c-4748-97b2-aa0791b2d9a6', 'PD176', 'Choco Orange Cake', 'Cakes', 'pico', 'count', 15.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('2f03290c-ba61-4b6c-920c-f87800bc528f', '9ba40daa-a15c-4748-97b2-aa0791b2d9a6', '5465d9a4-3d1b-4ebe-bd68-cdb5e523670e', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Choco Orange Cake', '9ba40daa-a15c-4748-97b2-aa0791b2d9a6')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

INSERT INTO public.boonz_products (product_id, boonz_product_name, product_category, physical_type, sourcing_channel, avg_cost)
VALUES ('42d8cbae-4829-4b3f-a476-75f770a5db26', 'LevelUp - Choco Banana Walnut Cake', 'Cakes', 'cake_wrapped', 'LevelUp Kitchen', NULL)
ON CONFLICT (product_id) DO NOTHING;
INSERT INTO public.pod_products (pod_product_id, custom_code, pod_product_name, product_category, machine_type, measurement_method, recommended_selling_price)
VALUES ('3f9a6f02-5025-42f1-b4ec-1cef9cf56cac', 'PD177', 'Choco Banana Walnut Cake', 'Cakes', 'pico', 'count', 15.00)
ON CONFLICT (pod_product_id) DO NOTHING;
INSERT INTO public.product_mapping (mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, mix_weight, source_of_supply)
VALUES ('5f35bfda-343f-4075-a102-9d5463e8fd15', '3f9a6f02-5025-42f1-b4ec-1cef9cf56cac', '42d8cbae-4829-4b3f-a476-75f770a5db26', NULL, 100.00, true, 'Active', NULL, 1.000, 'venue_team')
ON CONFLICT (mapping_id) DO NOTHING;
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Choco Banana Walnut Cake', '3f9a6f02-5025-42f1-b4ec-1cef9cf56cac')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;

-- Plaay 35g variant alias onto the EXISTING pod 'Plaay Tablets - Mix 35g'
INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id)
VALUES ('Plaay Tablet Chocolate 35g', '84f47441-0b90-4209-a36b-7605d395ee94')
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;
