# PRD-082 goal command

GOAL: Execute PRD-082 (docs/prds/PRD-082-planned-vs-filled-qty.md) AUTO mode. Self-run Dara/Cody/Stax. Keep PRD-082-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076+077. PRIOR ART SHIPPED PRD-044 — VERIFY + close residual. Flag qty_split_v1. SEQUENCE: reader-repoint BEFORE flipping pack semantics.

HARD GATES: settlement/statement output byte-unchanged on a sample period (billing must not move). engines md5 byte-identical; diff plan unchanged; conservation green. Cody signs (pack_dispatch_line, refill_dispatching). BEGIN..ROLLBACK; forward-only.

WS-1 AUDIT every reader of refill_dispatching.quantity (FE, stitch_pod_to_boonz, statement-of-account/settlement, dashboards, n8n). Classify planned vs packed. Repoint packed readers to filled_quantity. Verify settlement unchanged on sample.
WS-2 pack_dispatch_line: REMOVE 'quantity = v_total_picked'; keep filled_quantity + pack_outcome + from_wh_inventory_id; child rows keep filled_quantity; assert SUM(filled)<=quantity.
WS-3 edit_dispatch_qty: remove 'item_added — edit blocked' RAISE; keep role checks + edit log.
WS-4 Backfill: UPDATE quantity=original_quantity WHERE original_quantity NOT NULL AND packed AND quantity=filled_quantity AND quantity<>original_quantity; rows without original_quantity => flag manual.

T-TESTS: T1 edit 9->7 pack 7 => quantity=7 filled=7. T2 multi-batch parent intact. T3 edit item_added ok. T4 partial/not_filled keep quantity. T5 settlement unchanged. T6 conservation green. T7 diff plan unchanged.

CLOSE: CHANGELOG + registry; PRD-082 SHIPPED + EXECUTION-LOG; commit + push. ON BLOCKER (ambiguous reader; legacy rows w/o original_quantity): append PARKING_LOT.md, keep flag OFF until readers repointed.
