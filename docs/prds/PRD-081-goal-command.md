# PRD-081 goal command

GOAL: Execute PRD-081 (docs/prds/PRD-081-enforce-pack-rpc-only.md) AUTO mode. Self-run Dara/Cody/Stax. Keep PRD-081-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076+077. PRIOR ART SHIPPED PRD-028/068 — VERIFY + add guard. Flag pack_guard (warn|enforce|off).

HARD GATES: never block non-pick actions or is_m2m. WARN before ENFORCE. engines md5 byte-identical; plan output unchanged (diff identical); conservation must not regress and should improve. Cody signs (protected table refill_dispatching). BEGIN..ROLLBACK; forward-only.

WS-1 (Dara) trigger enforce_pack_via_rpc() BEFORE UPDATE ON refill_dispatching: IF NEW.packed AND NOT COALESCE(OLD.packed,false) AND NEW.action IN ('Refill','Add New','Add') AND COALESCE(current_setting('app.rpc_name',true),'')<>'pack_dispatch_line' THEN warn: INSERT refill_pack_bypass_log; enforce: RAISE. Allow all non-pick actions.
WS-2 Deploy WARN; run one packing cycle; collect bypass call sites from the log.
WS-3 (Stax) migrate every direct-write call site to pack_dispatch_line.
WS-4 Flip flag to ENFORCE.

T-TESTS: T1 direct pick-line pack outside RPC blocked (enforce). T2 Remove/M2W/M2M allowed. T3 warn logs attempt+source. T4 e2e RPC pack decrements warehouse_stock + credits consumer_stock. T5 conservation fewer violations. T6 diff plan unchanged.

CLOSE: CHANGELOG + registry; PRD-081 SHIPPED + EXECUTION-LOG; commit + push. ON BLOCKER (un-migrated call site): append PARKING_LOT.md, STAY in WARN, do not ENFORCE until cleared.
