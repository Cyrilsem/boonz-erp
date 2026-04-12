"""
fetch_fleet_state.py
Single source of truth for fleet state reads.
Called once at engine startup. Returns slots, velocity, machines.
"""

from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from math import ceil
from typing import TypedDict

from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()


# ── Types ──────────────────────────────────────────────────────────────────

class SlotState(TypedDict):
    machine_id: str
    machine_name: str
    aisle_code: str
    slot_name: str
    goods_name_raw: str
    pod_product_id: str | None
    match_method: str
    current_stock: int
    max_stock: int          # live from Weimi — physical ceiling
    effective_max_stock: int  # from v_slot_capacity (override or live)
    fill_pct: int
    is_broken: bool
    is_enabled: bool
    price_aed: float | None
    snapshot_at: str


class VelocityRecord(TypedDict):
    machine_id: str
    pod_product_name: str
    units_30d: float
    daily_avg: float        # units_30d / 30 — pre-computed


class MachineMetadata(TypedDict):
    machine_id: str
    official_name: str
    location_type: str
    include_in_refill: bool
    cabinet_count: int
    building_id: str | None
    source_of_supply: str | None
    venue_group: str | None
    status: str
    installation_date: str | None
    days_active: int | None    # computed: today - installation_date


class FleetState(TypedDict):
    slots: list[SlotState]
    velocity: dict[str, dict[str, VelocityRecord]]  # [machine_id][pod_product_name]
    machines: dict[str, MachineMetadata]             # [machine_id]
    fetched_at: str
    slot_count: int
    machine_count: int


# ── Client ─────────────────────────────────────────────────────────────────

def _get_client() -> Client:
    url = os.environ.get("SUPABASE_URL")
    # Accept both the canonical name and the legacy name present in .env
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        raise EnvironmentError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (or SUPABASE_SERVICE_KEY) "
            "must be set in .env"
        )
    return create_client(url, key)


# ── Individual fetchers ────────────────────────────────────────────────────

def _fetch_slots(client: Client) -> list[SlotState]:
    """
    Fetch all eligible, enabled, non-broken slots with effective capacity.
    Joins v_slot_capacity so Engine B gets override-aware max stock.
    """
    resp = (
        client.table("v_slot_capacity")
        .select(
            "machine_id, machine_name, aisle_code, slot_name, "
            "live_max_stock, effective_max_stock, capacity_source"
        )
        .limit(10000)
        .execute()
    )
    capacity_map: dict[tuple[str, str], int] = {
        (r["machine_id"], r["aisle_code"]): r["effective_max_stock"]
        for r in resp.data
    }

    resp2 = (
        client.table("v_live_shelf_stock")
        .select(
            "machine_id, machine_name, aisle_code, slot_name, "
            "goods_name_raw, pod_product_id, match_method, "
            "current_stock, max_stock, fill_pct, "
            "is_broken, is_enabled, price_aed, snapshot_at"
        )
        .eq("is_eligible_machine", True)
        .eq("is_enabled", True)
        .eq("is_broken", False)
        .limit(10000)
        .execute()
    )

    slots: list[SlotState] = []
    for r in resp2.data:
        key = (r["machine_id"], r["aisle_code"])
        slots.append(
            SlotState(
                machine_id=r["machine_id"],
                machine_name=r["machine_name"],
                aisle_code=r["aisle_code"],
                slot_name=r["slot_name"],
                goods_name_raw=r["goods_name_raw"] or "",
                pod_product_id=r.get("pod_product_id"),
                match_method=r.get("match_method", "unmatched"),
                current_stock=r["current_stock"],
                max_stock=r["max_stock"],
                effective_max_stock=capacity_map.get(key, r["max_stock"]),
                fill_pct=r["fill_pct"] or 0,
                is_broken=r["is_broken"],
                is_enabled=r["is_enabled"],
                price_aed=r.get("price_aed"),
                snapshot_at=r["snapshot_at"],
            )
        )
    return slots


def _fetch_velocity(client: Client) -> dict[str, dict[str, VelocityRecord]]:
    """
    30-day velocity per machine × pod_product_name.
    Returns nested dict: velocity[machine_id][pod_product_name]
    """
    # Try RPC first; fall back to direct view query if RPC doesn't exist yet
    try:
        resp = client.rpc("get_velocity_30d", {}).execute()
    except Exception:
        resp = (
            client.table("v_sales_history_attributed")
            .select("machine_id, pod_product_name, qty, transaction_date, delivery_status")
            .in_("delivery_status", ["Success", "Successful"])
            .gte("transaction_date", _thirty_days_ago())
            .limit(10000)
            .execute()
        )

    # Aggregate: sum qty per machine × product
    agg: dict[str, dict[str, float]] = {}
    for r in resp.data:
        mid = r["machine_id"]
        prod = r["pod_product_name"] or ""
        qty = float(r.get("qty") or 0)
        agg.setdefault(mid, {})
        agg[mid][prod] = agg[mid].get(prod, 0.0) + qty

    result: dict[str, dict[str, VelocityRecord]] = {}
    for mid, products in agg.items():
        result[mid] = {}
        for prod, units_30d in products.items():
            result[mid][prod] = VelocityRecord(
                machine_id=mid,
                pod_product_name=prod,
                units_30d=units_30d,
                daily_avg=round(units_30d / 30, 4),
            )
    return result


def _fetch_machines(client: Client) -> dict[str, MachineMetadata]:
    """
    All include_in_refill machines that haven't been repurposed.
    """
    resp = (
        client.table("machines")
        .select(
            "machine_id, official_name, location_type, include_in_refill, "
            "cabinet_count, building_id, source_of_supply, venue_group, "
            "status, installation_date, repurposed_at"
        )
        .eq("include_in_refill", True)
        .is_("repurposed_at", "null")
        .limit(10000)
        .execute()
    )

    today = datetime.now(timezone.utc).date()
    machines: dict[str, MachineMetadata] = {}
    for r in resp.data:
        inst = r.get("installation_date")
        days_active: int | None = None
        if inst:
            try:
                inst_date = datetime.fromisoformat(inst).date()
                days_active = (today - inst_date).days
            except ValueError:
                pass

        machines[r["machine_id"]] = MachineMetadata(
            machine_id=r["machine_id"],
            official_name=r["official_name"],
            location_type=r.get("location_type", "office"),
            include_in_refill=r["include_in_refill"],
            cabinet_count=r.get("cabinet_count") or 1,
            building_id=r.get("building_id"),
            source_of_supply=r.get("source_of_supply"),
            venue_group=r.get("venue_group"),
            status=r.get("status", "Active"),
            installation_date=inst,
            days_active=days_active,
        )
    return machines


# ── Main entry point ───────────────────────────────────────────────────────

def fetch_fleet_state() -> FleetState:
    """
    Fetch complete fleet state in parallel (3 concurrent queries).
    Returns typed FleetState dict ready for engine consumption.

    Raises EnvironmentError if credentials are missing.
    Raises RuntimeError if any fetch fails.
    """
    client = _get_client()
    results: dict[str, object] = {}
    errors: list[str] = []

    fetchers = {
        "slots": _fetch_slots,
        "velocity": _fetch_velocity,
        "machines": _fetch_machines,
    }

    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = {
            executor.submit(fn, client): name
            for name, fn in fetchers.items()
        }
        for future in as_completed(futures):
            name = futures[future]
            try:
                results[name] = future.result()
            except Exception as exc:
                errors.append(f"{name}: {exc}")

    if errors:
        raise RuntimeError(
            f"fetch_fleet_state failed on: {'; '.join(errors)}"
        )

    slots: list[SlotState] = results["slots"]      # type: ignore[assignment]
    velocity = results["velocity"]                  # type: ignore[assignment]
    machines = results["machines"]                  # type: ignore[assignment]

    return FleetState(
        slots=slots,
        velocity=velocity,
        machines=machines,
        fetched_at=datetime.now(timezone.utc).isoformat(),
        slot_count=len(slots),
        machine_count=len(machines),
    )


# ── Helpers ────────────────────────────────────────────────────────────────

def _thirty_days_ago() -> str:
    from datetime import timedelta
    return (
        datetime.now(timezone.utc) - timedelta(days=30)
    ).isoformat()


# ── CLI smoke test ─────────────────────────────────────────────────────────

if __name__ == "__main__":
    import json

    print("Fetching fleet state...")
    state = fetch_fleet_state()
    print(f"✅ Fetched at: {state['fetched_at']}")
    print(f"   Machines : {state['machine_count']}")
    print(f"   Slots    : {state['slot_count']}")
    print(f"   Velocity records: {sum(len(v) for v in state['velocity'].values())}")
    print()

    # Sample: first machine's slots
    first_mid = next(iter(state["machines"]))
    first_name = state["machines"][first_mid]["official_name"]
    machine_slots = [s for s in state["slots"] if s["machine_id"] == first_mid]
    print(f"Sample — {first_name} ({len(machine_slots)} slots):")
    for slot in machine_slots[:5]:
        vel = state["velocity"].get(first_mid, {}).get(slot["goods_name_raw"])
        daily = vel["daily_avg"] if vel else 0.0
        print(
            f"  {slot['aisle_code']} {slot['goods_name_raw'][:25]:<25} "
            f"stock={slot['current_stock']}/{slot['effective_max_stock']} "
            f"daily_avg={daily:.2f}"
        )
