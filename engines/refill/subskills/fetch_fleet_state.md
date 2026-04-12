# Subskill: fetch_fleet_state

**Status:** Stub — CC-11 not yet implemented

## Purpose

Single function that fetches complete fleet state in one call:

- All eligible machine slots from v_live_shelf_stock
- 30-day velocity per machine+product from v_sales_history_attributed
- Machine metadata from machines table

## Returns (planned)

{
slots: SlotState[], # one entry per machine+slot
velocity: VelocityMap, # machine_id+pod_product_name → daily_avg
machines: MachineMetadata[] # include_in_refill machines only
}

## Implementation target

engines/refill/subskills/fetch_fleet_state.py
See CC-11 task for full spec.
