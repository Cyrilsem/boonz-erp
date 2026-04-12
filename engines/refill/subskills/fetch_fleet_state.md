# Subskill: fetch_fleet_state

**Status:** Implemented — CC-11
**File:** engines/refill/subskills/fetch_fleet_state.py

## Purpose

Single entry point for all fleet state reads. Called once at engine startup.
Runs 3 Supabase queries in parallel (ThreadPoolExecutor, max_workers=3).

## Usage

```python
from engines.refill.subskills.fetch_fleet_state import fetch_fleet_state, FleetState

state: FleetState = fetch_fleet_state()
# state["slots"]    — list[SlotState], 385 slots across 22 machines
# state["velocity"] — dict[machine_id][pod_product_name] → VelocityRecord
# state["machines"] — dict[machine_id] → MachineMetadata
```

## Return shape

| Key           | Type                                 | Notes                                         |
| ------------- | ------------------------------------ | --------------------------------------------- |
| slots         | list[SlotState]                      | is_eligible + is_enabled + not broken only    |
| velocity      | dict[str, dict[str, VelocityRecord]] | 30d window, Success/Successful only           |
| machines      | dict[str, MachineMetadata]           | include_in_refill=true, repurposed_at IS NULL |
| fetched_at    | str                                  | ISO timestamp                                 |
| slot_count    | int                                  | len(slots)                                    |
| machine_count | int                                  | len(machines)                                 |

## Key field: effective_max_stock

SlotState carries both max_stock (live Weimi) and effective_max_stock
(override from slot_capacity_max if set, else max_stock). Engine B
always uses effective_max_stock as the capacity ceiling.

## Velocity join key

velocity[machine_id][goods_name_raw] — goods_name_raw from v_live_shelf_stock
matches pod_product_name in v_sales_history_attributed exactly.

## Raises

- EnvironmentError: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY missing
- RuntimeError: any of the 3 fetches fail (message names the failing fetch)

## CLI smoke test

python -m engines.refill.subskills.fetch_fleet_state
Expected output: machine count=22, slot count=385, velocity records>0
