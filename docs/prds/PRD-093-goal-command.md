# PRD-093 goal command

GOAL: Execute PRD-093 (docs/prds/PRD-093-consignment-sku-model.md) AUTO. Self-run Dara/Cody. Keep PRD-093-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. SHIP DARK (flag consignment_v1=off). Adds an additive column -> Cody REQUIRED.

HARD GATES: flag OFF (even with SKUs tagged) => diff_vs_golden IDENTICAL. Other Family A engines md5 byte-identical. Do NOT flip flag on. Cody PASS. BEGIN..ROLLBACK; forward-only.

WS-1 (Dara) boonz_products += is_consignment boolean default false (+ optional consignment_venue_id). Additive, inert.
WS-2 engine_add_pod (behind consignment_v1): consignment SKUs skip wh_avail gating, never emit blocked_no_wh/procurement_gaps, size to cap/venue policy. OFF => identical.
WS-3 Seed known VOX consignment SKUs (Aquafina, Ice Tea, M&M on VOX machines) as is_consignment=true; record the seed list in the EXECUTION-LOG for CS confirmation. Do NOT enable.
WS-4 Capture ON delta via rollback; report which shelves stop being WH-short. Leave flag OFF.

T-TESTS: T1 flag off (SKUs tagged) => golden identical. T2 flag on => VOX consignment shelves never blocked_no_wh/procurement. T3 conservation excludes consignment from WH balance. T4 non-consignment unchanged.

CLOSE: CHANGELOG + registry; PRD-093 SHIPPED DARK + EXECUTION-LOG (seed list + on-delta); commit+push. ON BLOCKER: PARK to MASTER-PARKING-LOT.md, do NOT ship.
