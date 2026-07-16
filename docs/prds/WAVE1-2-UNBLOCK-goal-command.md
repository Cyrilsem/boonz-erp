/goal WAVE1-2-UNBLOCK — build the freeze-INDEPENDENT scaffolding so parked 091/092 ship, and HOLD all engine surgery for a freeze window. AUTO; self-run Dara/Cody/Stax. Project ref: eizcexopcuoycuosittm. Basis: docs/prds/WAVE1-2-DESIGN-DECISIONS.md. Parking: docs/prds/MASTER-PARKING-LOT.md. Log to PRD-0NN-EXECUTION-LOG.md; commit+push (main==origin/main).

DESIGN RULINGS ADOPTED: 091 = Option 3 (signal-only). 092 = Option 1 (side-table). These make the work ADDITIVE — no engine-function edit, no freeze needed.

SAFE NOW (additive only; Cody review each migration; NEVER edit a Family-A engine function):
WS-091 (signal): create view public.v_shelf_expiry_risk(machine_id, shelf_id, pod_product_id, days_to_expiry_min, expiry_risk bool) from v_pod_inventory_latest + a new refill_policy_params.expiry_risk_days (default 7). Additive; consumed later by PRD-095. Set PRD-091 Status = SHIPPED (signal-only). Do NOT touch engine_add_pod.
WS-092 (side-table): create table public.refill_action_proposals(id, plan_date, machine_id, shelf_id, pod_product_id, kind text CHECK IN ('substitute','m2m','procurement'), detail jsonb, created_at) + a STANDALONE fn compute_nowh_proposals(p_plan_date) that reads that plan's blocked_no_wh shelves (pod_refills.clamp_reason='blocked_no_wh') and INSERTs substitute (find_substitutes_for_shelf w/ pickable WH) / m2m (surplus machine holding same pod_product above its need) / procurement proposals. Additive; validatable by row count. Set PRD-092 Status = SHIPPED (side-table + standalone fn). Do NOT touch engine_add_pod.
WS-093seed: PREPARE (do NOT enable) the VOX consignment seed list (Aquafina / Ice Tea / M&M on VOX machines) as is_consignment=true candidates; record in PRD-093 EXECUTION-LOG for CS confirmation.

HOLD FOR ENGINE-FREEZE (do NOT touch here — concurrent sessions are editing engines):
094 (swap caps), 095 (expiry-swap trigger), 096 (within-pod relocation), 097 (R7/R3 guards), AND the engine-wiring of 091/092 into engine_add_pod. At start, RECORD Family-A md5s (engine_add_pod, engine_swap_pod, engine_finalize_pod, pick_machines_for_refill). NEVER edit a Family-A engine function in this goal. If any engine item is requested -> PARK and STOP it.

GATES: additive migrations only; every new view/table/fn is INERT until consumed -> diff_vs_golden('golden_v2') IDENTICAL after each; conservation_check no new violations. `cody` PASS per migration. forward-only; npm build green. Do NOT enable any behaviour flag. Do NOT tune 089/090 thresholds (decision: they correctly don't bind; tuning = waste).

END: report {091 signal SHIPPED, 092 side-table+fn SHIPPED, 093 seed PREPARED}, confirm ZERO engine-function edits + Family-A md5 unchanged start-to-end, and list the held engine-surgery items awaiting a freeze window. Update MASTER-PARKING-LOT + WAVE1-2-DESIGN-DECISIONS statuses. Do NOT author Wave 3-5.

GLOBAL: branch/rollback before prod; referee green; Cody signs every migration; parks never block; nothing irreversible; NEVER edit a live engine function here.
