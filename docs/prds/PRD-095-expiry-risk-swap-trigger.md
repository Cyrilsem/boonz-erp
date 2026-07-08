# PRD-095: Expiry-risk swap trigger (rotate expired-but-selling)

Status: PARKED 2026-07-09 (rule F: Wave-2 spec drift vs rewritten engine / dependencies; + concurrent engine modification mid-run). NOT shipped. See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews.

## Why

SWAP rotation is triggered only by **zero velocity** (`v7=0 AND v30=0`). An expired-but-still-selling item is missed, and a fresh-but-slow item is treated the same as a spoiled one. Trigger rotation on **expiry-risk OR zero velocity** so soon-to-expire stock is rotated even while it sells.

## Design (Dara designs, Cody reviews)

1. In `engine_swap_pod`, extend the dead/rotate candidate set (behind `swap_expiry_v1`): also select shelves where `days_to_expiry_min < expiry_risk_days` (from `v_pod_inventory_latest`, or the PRD-091 `expiry_risk` tag if 091 has shipped), even with velocity>0. Resolve them via the normal substitute path (Pearson + fallback), sized by PRD-094 product-anchored cap.
2. Flag off ⇒ candidate set = today's (zero-velocity only) → identical.

## Gates

- Flag OFF ⇒ `diff_vs_golden`(golden_v2) IDENTICAL. Flag ON ⇒ capture delta; an expired-but-selling shelf gets a rotate/replace; conservation green; no oversubscription. Cody signs.
- **Dependency note:** if PRD-091's signal representation is still parked, read pod expiry directly here (self-contained) — do NOT block on 091.

## T-tests

- T1 flag off ⇒ golden_v2 identical.
- T2 flag on ⇒ a velocity>0 shelf with `days_to_expiry_min < expiry_risk_days` enters the rotate set and gets a substitute.
- T3 fresh shelves untouched.
- T4 conservation green; T5 no oversubscription.

## CLOSE

CHANGELOG + registry; PRD-095 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. Rollback = flag off.
