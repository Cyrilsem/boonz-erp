# /goal - PRD-070 (M2M approval routes to destination machine, not warehouse)

Paste into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. Dara design -> Cody review; migration FILE first; STOP for CS before apply. Under 4000 chars.

```
/goal Implement PRD-070 (docs/prds/PRD-070-m2m-approval-routes-to-destination-machine.md); read it first. Fix M2M transfer approval so it moves stock to the DESTINATION machine pod (same qty + same expiry) and shows in the dispatch list, with ZERO warehouse credit. Dara designs, Cody reviews (touches pod_inventory / warehouse_inventory / refill_dispatching / refill_plan_output - Articles 1,3,12). Migration FILE only; apply nothing until CS signs off; STOP for CS before apply. Idempotent. No em dashes.

CONTEXT (verified live 2026-07-01): receive_dispatch_line is already M2M-neutral (is_m2m Remove -> archive source pod no WH; is_m2m Refill -> write dest pod no WH). acknowledge_m2m_transfer stamps approval but needs m2m_transfer_id. wh_approve_remove_receipt (action=Remove only) calls receive_dispatch_line and is the warehouse-return path. Bug is in approval routing/flagging: live M2M rows exist with m2m_transfer_id=NULL and possibly is_m2m missing on one leg, so approval falls to a WH-crediting path and the dest leg never appears in dispatch.

STEPS
1. TRACE the exact FE approve call for the AMZ-1029 M2M transfer (WAVEMAKER-1006 / MC-2004 -> AMZ-1029): which RPC fires, and why it credits warehouse. Confirm whether the source Remove leg and dest Refill leg both carry is_m2m + a shared m2m_transfer_id. Report the call site.
2. PAIRING INTEGRITY: make mark_internal_transfer + convert_removes_to_m2m_transfer always set is_m2m=true AND a shared m2m_transfer_id on BOTH legs. Backfill existing is_m2m rows with NULL m2m_transfer_id into source+dest qty-matched groups (same product+expiry).
3. approve_m2m_transfer(p_transfer_id): atomic + idempotent. Validate pair qty-match + expiry carry-over, run receive on BOTH legs (source pod out, dest pod in same qty+expiry, no WH), stamp wh_approved.
4. HARD GUARD: no is_m2m row may credit warehouse via ANY path (belt-and-suspenders in receive_dispatch_line Remove+Refill branches). Make wh_approve_remove_receipt REJECT is_m2m rows pointing to approve_m2m_transfer.
5. DISPATCH VISIBILITY: ensure the dest Refill M2M leg surfaces in the destination machine's dispatch/pick list (refill_plan_output / v_dispatch_pick_list); confirm the stitch/dispatch bridge does not drop M2M dest legs.
6. DRY-RUN the live AMZ-1029 transfer end to end BEGIN..ROLLBACK: assert warehouse_stock delta = 0 and dest pod +qty at the correct expiry. Show me the before/after.

Wire the FE approve button (Stax) to approve_m2m_transfer for M2M rows; leave wh_approve_remove_receipt for genuine machine->warehouse returns.

Deliver: the traced call site + root cause, the Dara design, the Cody verdict, the migration FILE, the dry-run WH-delta=0 proof, and the FE wiring diff. Do NOT disturb the already-completed Starbucks MC-2004 -> AMZ-1029 transfer.
```

PRD: `boonz-erp/docs/prds/PRD-070-m2m-approval-routes-to-destination-machine.md`.

```

```
