# Refill Overrides — /refill UI Mechanic

**From:** CS-17 fast-path, 2026-04-10

## Override actions (5)

| Action               | Effect                                                             | Reason required |
| -------------------- | ------------------------------------------------------------------ | --------------- |
| `accept`             | Engine D proposal ships as-is                                      | No              |
| `reject_with_reason` | Slot not refilled tomorrow. Engine 1 avoids same proposal 30 days. | Yes             |
| `modify_quantity`    | Product stays, quantity changes                                    | Yes             |
| `swap_product`       | Replace product (picker filtered by coexistence + travel-scope)    | Yes             |
| `escalate`           | Defer — neither refill nor reject, revisit next cycle              | No              |

## Reason codes (10)

| Code                              | Learning?                          |
| --------------------------------- | ---------------------------------- |
| `stockout_at_warehouse`           | **EXCLUDED** — operational         |
| `one_off_client_request`          | Feeds learning                     |
| `driver_logistics_constraint`     | **EXCLUDED** — operational         |
| `expiry_concern`                  | Feeds learning                     |
| `quality_issue`                   | Feeds learning                     |
| `operator_knows_better`           | Feeds learning                     |
| `seasonal_timing`                 | Feeds learning                     |
| `test_in_progress`                | Feeds learning                     |
| `partnership_requirement`         | Feeds learning                     |
| `rate_limit_exceeded_manual_push` | **EXCLUDED** — operator escalation |

Excluded codes are operational facts about the world (warehouse stock, driver capacity, operator override of ceiling) and tell Engine D nothing about whether its proposal was _strategically_ right. The other 7 codes carry strategic signal and feed Engine D's learning loop.

## Data model

Every override writes to `decision_log`:

- machine_id, shelf_code, pod_product_id
- proposed_decision (JSON blob of what Engine D wanted)
- operator_action (one of 5)
- operator_reason (one of 10, nullable for accept/escalate)
- operator_notes (free text, optional)
- fed_to_learning (boolean, derived)
- created_at, created_by

## Follow-up

CC-07 implements the `/refill` UI with this spec as input.
