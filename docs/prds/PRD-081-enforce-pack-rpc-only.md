# PRD-081: Enforce pack_dispatch_line as sole warehouse mutation path

Status: PARKED 2026-07-07 (prior art verified live; blocked on referee candidate-capture / branch-data + Cody+CS sign-off — see EXECUTION-LOG).
Owner: CS. Mode: AUTO with hard gates. Dara trigger, Cody reviews, Stax migrates FE call sites.

## Why

Warehouse `warehouse_stock → consumer_stock` movement lives only in `pack_dispatch_line`. Audit §3-C / field bugs 3/4/8 showed the FE could set `packed=true` directly, skipping the decrement. PRD-028/068 hardened dispatch state + conservation; this closes the remaining door with a guard and enumerates any surviving bypass call sites.

## Design (Dara designs, Cody reviews, Stax wires)

1. **Audit** (warn phase): trigger `enforce_pack_via_rpc()` BEFORE UPDATE on `refill_dispatching` — if `NEW.packed AND NOT OLD.packed AND NEW.action IN ('Refill','Add New','Add') AND current_setting('app.rpc_name',true) <> 'pack_dispatch_line'` → in `warn`: log to `refill_pack_bypass_log`; in `enforce`: RAISE. Non-pick actions (Remove/M2W/M2M) always allowed.
2. **Run one packing cycle in warn** to enumerate remaining FE/n8n call sites.
3. **Migrate** any surviving direct-write call sites to call `pack_dispatch_line` (Stax).
4. **Flip to enforce.**

## Gates

- Never blocks non-pick actions or `is_m2m`. Warn-before-enforce. Engines md5 byte-identical. Plan output unaffected (diff identical — this is a write-path guard). Conservation (PRD-077) should measurably IMPROVE (fewer violations). Cody signs. Flag `pack_guard` (warn|enforce|off).

## T-tests

- T1 direct `UPDATE ... packed=true` on a Refill line outside RPC ⇒ rejected (enforce).
- T2 Remove/M2W/M2M packed=true ⇒ allowed.
- T3 warn mode logs the attempt with source.
- T4 e2e pack via RPC decrements `warehouse_stock`, credits `consumer_stock`.
- T5 conservation gate shows fewer violations post-enforce.
- T6 diff = plan output unchanged.

## CLOSE

CHANGELOG + registry; PRD-081 SHIPPED + EXECUTION-LOG; commit + push. Rollback = flag warn/off or drop trigger.
