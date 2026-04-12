"""
engine_b_quantity.py
Engine B — Quantity Calculator.

Takes FleetState (from fetch_fleet_state) and PortfolioResult (from
Engine 1) and computes per-slot refill quantities using the canonical
formula.

Returns a typed RefillPlan — the first actionable output for driver dispatch.

READ ONLY — no DB writes.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from math import ceil
from typing import TypedDict

from dotenv import load_dotenv
from supabase import create_client, Client

try:
    from engines.refill.subskills.fetch_fleet_state import (
        FleetState,
        MachineMetadata,
        fetch_fleet_state,
    )
    from engines.refill.engine_1_portfolio import (
        PortfolioResult,
        ProductClassification,
        run_engine_1,
    )
except ImportError:
    from subskills.fetch_fleet_state import (  # type: ignore[no-redef]
        FleetState,
        MachineMetadata,
        fetch_fleet_state,
    )
    from engine_1_portfolio import (  # type: ignore[no-redef]
        PortfolioResult,
        ProductClassification,
        run_engine_1,
    )

load_dotenv()


# ── Mode parameters ─────────────────────────────────────────────────────────

_MODE_PARAMS: dict[str, tuple[int, int]] = {
    # mode → (days_cover, floor_qty)
    "NORMAL":       (21, 4),
    "CONSERVATIVE": (21, 3),
    "RAMP_UP":      (10, 5),
    # SUMMER: activate May–Sep when venue_group='VOX', overrides NORMAL
    # "SUMMER": (7, 6),
}

# ── Keyword fallback for attr_drink detection ────────────────────────────────

_DRINK_KEYWORDS = frozenset({
    "water", "juice", "drink", "soda", "pepsi", "cola", "sprite",
    "energy", "red bull", "vitamin", "sparkling", "coffee", "tea",
    "aquafina", "perrier", "evian", "popit", "yopro", "protein milk",
})


# ── Output types ─────────────────────────────────────────────────────────────

class SlotRefillLine(TypedDict):
    # Identity
    machine_id: str
    machine_name: str
    aisle_code: str
    slot_name: str
    pod_product_name: str       # goods_name_raw from FleetState
    pod_product_id: str | None

    # Stock state
    current_stock: int
    effective_max_stock: int    # from v_slot_capacity
    live_max_stock: int         # raw from Weimi, for audit

    # Engine 1 inputs
    final_action: str           # from PortfolioResult
    guardrail_override: str | None

    # Engine B outputs — always log both
    target_qty: int
    refill_qty: int             # 0 means skip
    daily_avg: float
    days_cover: int
    mode: str                   # NORMAL | CONSERVATIVE | RAMP_UP

    # Flags
    skip_reason: str | None     # None if refill_qty > 0
    dead_machine: bool
    is_swap_minimum: bool
    explanation: str            # 1 sentence for operator

    # Relative velocity + local signal flags
    relative_velocity: float    # daily_avg / machine_avg, or 0.0 if no avg
    is_local_hero: bool         # sells ≥ 1.5x machine avg AND slot score ≥ 4.5
    local_hero_reason: str | None  # e.g. "3.2x machine avg velocity"
    is_local_dead: bool         # WIND DOWN/ROTATE OUT + velocity_30d < 0.1


class RefillPlan(TypedDict):
    lines: list[SlotRefillLine]
    run_at: str
    machine_count: int
    slot_count: int
    total_refill_units: int     # sum of all refill_qty
    skip_count: int             # refill_qty == 0
    dead_machine_count: int     # distinct machines flagged dead
    swap_minimum_count: int
    local_hero_count: int       # slots detected as local heroes
    local_dead_count: int       # slots capped as local dead


# ── DB client ────────────────────────────────────────────────────────────────

def _get_client() -> Client:
    url = os.environ.get("SUPABASE_URL")
    key = (
        os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        or os.environ.get("SUPABASE_SERVICE_KEY")
    )
    if not url or not key:
        raise EnvironmentError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (or SUPABASE_SERVICE_KEY) "
            "must be set in .env"
        )
    return create_client(url, key)


# ── Mode assignment ──────────────────────────────────────────────────────────

def assign_mode(machine: MachineMetadata, sales_30d: int) -> str:
    """
    Assign refill mode for a machine. Priority order:
      1. RAMP_UP      — machine days_active < 30
      2. NORMAL       — venue_group == 'VOX'  (NOT location_type)
      3. CONSERVATIVE — all others

    SUMMER mode (days_cover=7, floor_qty=6) is NOT active (April).
    # SUMMER: activate May-Sep when venue_group='VOX', overrides NORMAL
    """
    days_active = machine.get("days_active")
    if days_active is not None and days_active < 30:
        return "RAMP_UP"

    if (machine.get("venue_group") or "").upper() == "VOX":
        return "NORMAL"

    return "CONSERVATIVE"


# ── Dead machine detection ───────────────────────────────────────────────────

def is_dead_machine(sales_7d: int, sales_30d: int) -> bool:
    return sales_7d < 5 and sales_30d < 20


# ── Canonical formula ────────────────────────────────────────────────────────

def calculate_slot_qty(
    daily_avg: float,
    days_cover: int,
    floor_qty: int,
    effective_max_stock: int,
    current_stock: int,
    action_cap: int | None,     # None = no cap; int = hard ceiling
) -> tuple[int, int]:
    """Returns (target_qty, refill_qty)."""
    velocity_target = ceil(daily_avg * days_cover)
    target_qty = max(velocity_target, floor_qty)
    target_qty = min(target_qty, effective_max_stock)
    if action_cap is not None:
        target_qty = min(target_qty, action_cap)
    refill_qty = max(target_qty - current_stock, 0)
    return target_qty, refill_qty


# ── Product attr_drink fetch ─────────────────────────────────────────────────

def _is_drink_by_keyword(goods_name_raw: str) -> bool:
    """Keyword fallback for attr_drink when DB join is unavailable."""
    name_lower = goods_name_raw.lower()
    return any(kw in name_lower for kw in _DRINK_KEYWORDS)


def _fetch_product_attrs(client: Client) -> dict[str, bool]:
    """
    Returns dict: pod_product_id → attr_drink (True = is a drink).

    Attempts DB join: product_mapping → boonz_products.attr_drink.
    Falls back to empty dict (triggers per-slot keyword fallback) if the
    join returns < 50 results, indicating a mapping gap.
    """
    try:
        mapping_resp = (
            client.table("product_mapping")
            .select("pod_product_id, boonz_product_id")
            .limit(10000)
            .execute()
        )
        mapping_rows = mapping_resp.data or []

        if len(mapping_rows) < 50:
            return {}  # Too sparse — use keyword fallback per slot

        boonz_ids = list({
            r["boonz_product_id"]
            for r in mapping_rows
            if r.get("boonz_product_id")
        })
        attr_resp = (
            client.table("boonz_products")
            .select("id, attr_drink")
            .in_("id", boonz_ids)
            .limit(10000)
            .execute()
        )
        attr_map: dict[str, bool] = {
            r["id"]: bool(r.get("attr_drink") or False)
            for r in (attr_resp.data or [])
        }

        # If ANY boonz variant for a pod_product_id is a drink, mark as drink
        result: dict[str, bool] = {}
        for row in mapping_rows:
            ppid = row.get("pod_product_id")
            bid = row.get("boonz_product_id")
            if ppid and bid:
                result[ppid] = result.get(ppid, False) or attr_map.get(bid, False)
        return result

    except Exception:
        return {}  # Fall through to per-slot keyword fallback


# ── Machine sales aggregation ────────────────────────────────────────────────

def _machine_sales_totals(
    fleet: FleetState,
    client: Client,
) -> dict[str, tuple[int, int]]:
    """
    Returns dict: machine_id → (sales_7d, sales_30d).

    sales_30d: computed from FleetState.velocity (already in memory).
    sales_7d:  one additional Supabase query.
    """
    # 30d from velocity
    sales_30d: dict[str, int] = {}
    for mid, products in fleet["velocity"].items():
        sales_30d[mid] = sum(int(v["units_30d"]) for v in products.values())

    # 7d via a single query
    sales_7d: dict[str, int] = {}
    try:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()
        resp = (
            client.table("v_sales_history_attributed")
            .select("machine_id, qty")
            .in_("delivery_status", ["Success", "Successful"])
            .gte("transaction_date", cutoff)
            .limit(10000)
            .execute()
        )
        for r in (resp.data or []):
            mid = r["machine_id"]
            sales_7d[mid] = sales_7d.get(mid, 0) + int(r.get("qty") or 0)
    except Exception:
        # If 7d fetch fails, all machines report 0 sales_7d → conservative
        pass

    # Merge: include all machines in the fleet
    result: dict[str, tuple[int, int]] = {}
    all_mids = set(sales_30d) | set(fleet["machines"])
    for mid in all_mids:
        result[mid] = (sales_7d.get(mid, 0), sales_30d.get(mid, 0))
    return result


# ── Main entry point ─────────────────────────────────────────────────────────

def run_engine_b(
    fleet: FleetState,
    portfolio: PortfolioResult,
) -> RefillPlan:
    """
    Compute refill quantities for all slots.

    fleet:     from fetch_fleet_state()
    portfolio: from run_engine_1()

    Returns RefillPlan. READ ONLY — no DB writes.
    """
    client = _get_client()

    # ── Startup fetches ────────────────────────────────────────────────────
    product_attrs = _fetch_product_attrs(client)
    use_keyword_fallback = len(product_attrs) < 50

    machine_sales = _machine_sales_totals(fleet, client)

    # ── Classification lookup: (machine_id, aisle_code) → classification ──
    cls_by_slot: dict[tuple[str, str], ProductClassification] = {
        (c["machine_id"], c["aisle_code"]): c
        for c in portfolio["classifications"]
    }

    # ── Per-machine derived data ───────────────────────────────────────────
    machine_mode: dict[str, str] = {}
    machine_dead: dict[str, bool] = {}

    for mid, machine in fleet["machines"].items():
        s7, s30 = machine_sales.get(mid, (0, 0))
        machine_mode[mid] = assign_mode(machine, s30)
        machine_dead[mid] = is_dead_machine(s7, s30)

    # ── Pre-compute machine average daily velocity ─────────────────────────
    machine_avg_velocity: dict[str, float] = {}
    for mid, products in fleet["velocity"].items():
        avgs = [v["daily_avg"] for v in products.values() if v["daily_avg"] > 0]
        machine_avg_velocity[mid] = sum(avgs) / len(avgs) if avgs else 0.0

    # ── Slot processing ────────────────────────────────────────────────────
    lines: list[SlotRefillLine] = []

    for slot in fleet["slots"]:
        machine_id    = slot["machine_id"]
        aisle_code    = slot["aisle_code"]
        current_stock = slot["current_stock"]
        effective_max = slot["effective_max_stock"]
        live_max      = slot["max_stock"]
        goods_name    = slot.get("goods_name_raw") or ""
        pod_pid       = slot.get("pod_product_id")

        # 1. Classification
        cls = cls_by_slot.get((machine_id, aisle_code))
        final_action      = cls["final_action"]      if cls else "KEEP"
        guardrail_override = cls["guardrail_override"] if cls else None

        # 2. Mode params
        mode = machine_mode.get(machine_id, "CONSERVATIVE")
        days_cover, floor_qty = _MODE_PARAMS[mode]

        # 3. Dead machine — cap DOUBLE_DOWN at KEEP
        dead = machine_dead.get(machine_id, False)
        if dead and final_action == "DOUBLE_DOWN":
            final_action = "KEEP"

        # 4. Pre-compute velocity and lifecycle signals for ALL slots
        vel = fleet["velocity"].get(machine_id, {}).get(goods_name)
        daily_avg_raw = vel["daily_avg"] if vel else 0.0
        machine_avg = machine_avg_velocity.get(machine_id, 0.0)
        relative_velocity = (
            round(daily_avg_raw / machine_avg, 3)
            if machine_avg > 0 and daily_avg_raw > 0
            else 0.0
        )

        # 5. Slot lifecycle lookup
        lc_rec = (
            fleet["slot_lifecycle"].get(machine_id, {}).get(pod_pid)
            if pod_pid else None
        )
        lc_signal = lc_rec["signal"] if lc_rec else None
        lc_score = lc_rec["score"] if lc_rec else 0.0

        # 6. Local hero detection
        is_local_hero = (
            relative_velocity >= 1.5
            and lc_signal in ("KEEP", "KEEP GROWING", "WATCH")
            and lc_score >= 4.5
        )
        local_hero_reason: str | None = (
            f"{relative_velocity:.1f}x machine avg velocity"
            if is_local_hero else None
        )

        # 7. Local dead detection
        is_local_dead = bool(
            lc_rec
            and lc_signal in ("WIND DOWN", "ROTATE OUT")
            and lc_rec["velocity_30d"] < 0.1
            and not is_local_hero
        )

        # 8. Local hero DISCONTINUE override
        if final_action == "DISCONTINUE" and is_local_hero:
            final_action = "MONITOR"
            guardrail_override = "LOCAL_HERO_PROTECTED"

        # ── Path A: DISCONTINUE — always include, always skip ─────────────
        if final_action == "DISCONTINUE":
            reason = (
                "DISCONTINUE — Engine 1 classification"
                + (f" ({guardrail_override})" if guardrail_override else "")
            )
            lines.append(SlotRefillLine(
                machine_id=machine_id,
                machine_name=slot["machine_name"],
                aisle_code=aisle_code,
                slot_name=slot["slot_name"],
                pod_product_name=goods_name,
                pod_product_id=pod_pid,
                current_stock=current_stock,
                effective_max_stock=effective_max,
                live_max_stock=live_max,
                final_action=final_action,
                guardrail_override=guardrail_override,
                target_qty=0,
                refill_qty=0,
                daily_avg=0.0,
                days_cover=days_cover,
                mode=mode,
                skip_reason=reason,
                dead_machine=dead,
                is_swap_minimum=False,
                explanation=reason + ".",
                relative_velocity=relative_velocity,
                is_local_hero=False,
                local_hero_reason=None,
                is_local_dead=False,
            ))
            continue

        # ── Path B: Dead machine ───────────────────────────────────────────
        if dead:
            if current_stock >= floor_qty:
                lines.append(SlotRefillLine(
                    machine_id=machine_id,
                    machine_name=slot["machine_name"],
                    aisle_code=aisle_code,
                    slot_name=slot["slot_name"],
                    pod_product_name=goods_name,
                    pod_product_id=pod_pid,
                    current_stock=current_stock,
                    effective_max_stock=effective_max,
                    live_max_stock=live_max,
                    final_action=final_action,
                    guardrail_override=guardrail_override,
                    target_qty=current_stock,
                    refill_qty=0,
                    daily_avg=0.0,
                    days_cover=days_cover,
                    mode=mode,
                    skip_reason="Dead machine — stock at or above floor",
                    dead_machine=True,
                    is_swap_minimum=False,
                    explanation="Dead machine — stock sufficient, no refill.",
                    relative_velocity=relative_velocity,
                    is_local_hero=False,
                    local_hero_reason=None,
                    is_local_dead=False,
                ))
            else:
                target_qty = floor_qty
                refill_qty = max(target_qty - current_stock, 0)
                lines.append(SlotRefillLine(
                    machine_id=machine_id,
                    machine_name=slot["machine_name"],
                    aisle_code=aisle_code,
                    slot_name=slot["slot_name"],
                    pod_product_name=goods_name,
                    pod_product_id=pod_pid,
                    current_stock=current_stock,
                    effective_max_stock=effective_max,
                    live_max_stock=live_max,
                    final_action=final_action,
                    guardrail_override=guardrail_override,
                    target_qty=target_qty,
                    refill_qty=refill_qty,
                    daily_avg=0.0,
                    days_cover=days_cover,
                    mode=mode,
                    skip_reason=None,
                    dead_machine=True,
                    is_swap_minimum=False,
                    explanation=(
                        f"Dead machine — floor fill only: "
                        f"{current_stock} → {target_qty}."
                    ),
                    relative_velocity=relative_velocity,
                    is_local_hero=False,
                    local_hero_reason=None,
                    is_local_dead=False,
                ))
            continue

        # ── Path C: Normal slots ───────────────────────────────────────────

        # 9. Velocity (already computed as daily_avg_raw above)
        daily_avg = daily_avg_raw

        # 10. Determine attr_drink (needed for swap minimum)
        if pod_pid and pod_pid in product_attrs:
            attr_drink = product_attrs[pod_pid]
        elif use_keyword_fallback or pod_pid is None:
            attr_drink = _is_drink_by_keyword(goods_name)
        else:
            attr_drink = False

        # 11. Local dead cap — no new stock added, include for operator visibility
        if is_local_dead:
            target_qty = current_stock
            refill_qty = 0
            vel_str = f"{lc_rec['velocity_30d']:.2f}" if lc_rec else "0.00"
            skip_reason_c: str | None = (
                f"LOCAL_DEAD — slot signal {lc_signal}, vel {vel_str}/day"
            )
            explanation = skip_reason_c
            lines.append(SlotRefillLine(
                machine_id=machine_id,
                machine_name=slot["machine_name"],
                aisle_code=aisle_code,
                slot_name=slot["slot_name"],
                pod_product_name=goods_name,
                pod_product_id=pod_pid,
                current_stock=current_stock,
                effective_max_stock=effective_max,
                live_max_stock=live_max,
                final_action=final_action,
                guardrail_override=guardrail_override,
                target_qty=target_qty,
                refill_qty=0,
                daily_avg=daily_avg,
                days_cover=days_cover,
                mode=mode,
                skip_reason=skip_reason_c,
                dead_machine=False,
                is_swap_minimum=False,
                explanation=explanation,
                relative_velocity=relative_velocity,
                is_local_hero=False,
                local_hero_reason=None,
                is_local_dead=True,
            ))
            continue

        # 12. Swap minimum (no velocity history)
        is_swap_min = False
        if daily_avg == 0.0:
            swap_min = 6 if attr_drink else 4
            target_qty = min(swap_min, effective_max)
            refill_qty = max(target_qty - current_stock, 0)
            is_swap_min = True
            explanation = (
                f"No velocity history — swap minimum ({'drink' if attr_drink else 'non-drink'}): "
                f"{current_stock} → {target_qty}."
            )
        else:
            # 13. Action cap logic
            action_cap: int | None = None
            cap_note = ""
            if final_action == "MONITOR":
                if is_local_hero:
                    # Local hero: override MONITOR cap to 100%
                    action_cap = None
                    cap_note = (
                        f" (Local Hero override — {relative_velocity:.1f}x machine avg."
                        " Global MONITOR signal overridden by local performance)"
                    )
                else:
                    action_cap = int(effective_max * 0.70)
                    cap_note = " (capped 70%)"

            target_qty, refill_qty = calculate_slot_qty(
                daily_avg=daily_avg,
                days_cover=days_cover,
                floor_qty=floor_qty,
                effective_max_stock=effective_max,
                current_stock=current_stock,
                action_cap=action_cap,
            )
            explanation = (
                f"{final_action} — daily_avg={daily_avg:.2f}, "
                f"{days_cover}d cover{cap_note}: "
                f"{current_stock} → {target_qty}."
            )

        skip_reason = (
            None if refill_qty > 0
            else "Already at or above target"
        )

        lines.append(SlotRefillLine(
            machine_id=machine_id,
            machine_name=slot["machine_name"],
            aisle_code=aisle_code,
            slot_name=slot["slot_name"],
            pod_product_name=goods_name,
            pod_product_id=pod_pid,
            current_stock=current_stock,
            effective_max_stock=effective_max,
            live_max_stock=live_max,
            final_action=final_action,
            guardrail_override=guardrail_override,
            target_qty=target_qty,
            refill_qty=refill_qty,
            daily_avg=daily_avg,
            days_cover=days_cover,
            mode=mode,
            skip_reason=skip_reason,
            dead_machine=False,
            is_swap_minimum=is_swap_min,
            explanation=explanation,
            relative_velocity=relative_velocity,
            is_local_hero=is_local_hero,
            local_hero_reason=local_hero_reason,
            is_local_dead=False,
        ))

    # ── Aggregate ──────────────────────────────────────────────────────────
    dead_mids = {line["machine_id"] for line in lines if line["dead_machine"]}

    return RefillPlan(
        lines=lines,
        run_at=datetime.now(timezone.utc).isoformat(),
        machine_count=fleet["machine_count"],
        slot_count=len(lines),
        total_refill_units=sum(line["refill_qty"] for line in lines),
        skip_count=sum(1 for line in lines if line["refill_qty"] == 0),
        dead_machine_count=len(dead_mids),
        swap_minimum_count=sum(1 for line in lines if line["is_swap_minimum"]),
        local_hero_count=sum(1 for line in lines if line["is_local_hero"]),
        local_dead_count=sum(1 for line in lines if line["is_local_dead"]),
    )


# ── CLI smoke test ────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("Fetching fleet state...")
    fleet = fetch_fleet_state()
    print(f"  ✅  {fleet['machine_count']} machines, {fleet['slot_count']} slots")

    print("Running Engine 1...")
    portfolio = run_engine_1(fleet)
    print(f"  ✅  {portfolio['slot_count']} classifications")

    print("Running Engine B...")
    plan = run_engine_b(fleet, portfolio)
    print(f"  ✅  {plan['slot_count']} lines computed")

    print()
    print(f"Refill Plan — {plan['run_at']}")
    print(f"Machines     : {plan['machine_count']}")
    print(f"Total slots  : {plan['slot_count']}")
    to_refill = sum(1 for line in plan["lines"] if line["refill_qty"] > 0)
    print(f"To refill    : {to_refill} slots (refill_qty > 0)")
    print(f"Skip         : {plan['skip_count']} slots")
    print(f"Dead machines: {plan['dead_machine_count']}")
    print(f"Swap minimums: {plan['swap_minimum_count']}")
    print(f"Total units  : {plan['total_refill_units']}")

    # Mode distribution
    print()
    print("Mode distribution:")
    mode_machines: dict[str, set[str]] = {}
    for line in plan["lines"]:
        mode_machines.setdefault(line["mode"], set()).add(line["machine_id"])
    for mode_label in ("NORMAL", "CONSERVATIVE", "RAMP_UP"):
        mids = mode_machines.get(mode_label, set())
        suffix = " (VOX)" if mode_label == "NORMAL" else ""
        print(f"  {mode_label:<12}: {len(mids)} machines{suffix}")

    # Top 10 by refill_qty
    print()
    print("Top 10 by refill_qty:")
    top10 = sorted(plan["lines"], key=lambda l: l["refill_qty"], reverse=True)[:10]
    for line in top10:
        print(
            f"  [{line['machine_name'][:20]:<20}] "
            f"{line['aisle_code']:<7} "
            f"{line['pod_product_name'][:22]:<22} "
            f"curr={line['current_stock']} → target={line['target_qty']} "
            f"(refill {line['refill_qty']}) [{line['mode']}] [{line['final_action']}]"
        )

    # Dead machines summary
    dead_mid_set = {line["machine_id"] for line in plan["lines"] if line["dead_machine"]}
    if dead_mid_set:
        print()
        print("Dead machines:")
        # Re-use the already-fetched machine_sales for display
        client_tmp = _get_client()
        sales_tmp = _machine_sales_totals(fleet, client_tmp)
        for mid in sorted(dead_mid_set):
            meta = fleet["machines"].get(mid)
            name = meta["official_name"] if meta else mid
            s7, s30 = sales_tmp.get(mid, (0, 0))
            print(f"  [{name}] sales_7d={s7} sales_30d={s30} → floor-only")

    # DISCONTINUE slots
    disc_lines = [line for line in plan["lines"] if line["final_action"] == "DISCONTINUE"]
    if disc_lines:
        print()
        print(f"DISCONTINUE slots (refill_qty=0) — {len(disc_lines)} total:")
        for line in disc_lines[:15]:
            override_str = f" ({line['guardrail_override']})" if line["guardrail_override"] else ""
            print(
                f"  [{line['machine_name'][:20]:<20}] "
                f"{line['aisle_code']:<7} "
                f"{line['pod_product_name'][:22]:<22} "
                f"→ SKIP{override_str}"
            )
        if len(disc_lines) > 15:
            print(f"  … and {len(disc_lines) - 15} more")

    print()
    print("✅  Engine B smoke test complete.")
