"""
engine_d_decider.py
Engine D — Decider + Rate Limiter.

Bonds Engine B (quantities) + Engine C (swap candidates) into unified
plan lines, enforces §9 rate limits, writes to refill_plan_output and
decision_log.

dry_run=True (default) — never writes to DB without explicit flag.
"""

from __future__ import annotations

import json
import os
import uuid
from datetime import date, datetime, timedelta, timezone
from typing import TypedDict

from dotenv import load_dotenv
from supabase import create_client, Client

try:
    from engines.refill.subskills.fetch_fleet_state import FleetState, fetch_fleet_state
    from engines.refill.engine_1_portfolio import PortfolioResult, ProductClassification, run_engine_1
    from engines.refill.engine_b_quantity import RefillPlan, SlotRefillLine, run_engine_b
    from engines.refill.engine_c_swap import SwapPlan, SlotSwapProposal, SwapCandidate, run_engine_c
except ImportError:
    from subskills.fetch_fleet_state import FleetState, fetch_fleet_state               # type: ignore[no-redef]
    from engine_1_portfolio import PortfolioResult, ProductClassification, run_engine_1  # type: ignore[no-redef]
    from engine_b_quantity import RefillPlan, SlotRefillLine, run_engine_b               # type: ignore[no-redef]
    from engine_c_swap import SwapPlan, SlotSwapProposal, SwapCandidate, run_engine_c    # type: ignore[no-redef]

load_dotenv()


# ── Rate limits (§9.2 — hardcoded Phase 1) ──────────────────────────────────

RATE_LIMITS: dict[str, int] = {
    "max_slot_changes_per_machine":      2,
    "max_machines_with_changes_per_day": 5,
    "max_total_slot_changes_per_day":    10,
    "min_days_between_slot_changes":     14,
}

# ── Priority tiers for swap truncation (§9.3) ────────────────────────────────
# Higher = higher priority = keep first when limits are hit.
_SWAP_PRIORITY: dict[tuple[str, str], int] = {
    ("DISCONTINUE",  "HIGH"):   4,
    ("SWAP_MINIMUM", "HIGH"):   3,
    ("DISCONTINUE",  "MEDIUM"): 2,
    ("SWAP_MINIMUM", "MEDIUM"): 2,
    ("DISCONTINUE",  "LOW"):    1,
    ("SWAP_MINIMUM", "LOW"):    1,
}


# ── Output types ─────────────────────────────────────────────────────────────

class FinalPlanLine(TypedDict):
    # Maps to refill_plan_output columns
    plan_date: str
    machine_name: str
    machine_priority: int
    shelf_code: str
    pod_product_name: str
    boonz_product_name: str
    action: str                 # 'REFILL' | 'SWAP' | 'REMOVE' | 'ADD NEW'
    quantity: int
    current_stock: int
    max_stock: int
    smart_target: int
    global_score: float | None
    fill_pct: float | None
    comment: str
    operator_status: str        # always 'pending'
    # Internal — NOT written to DB
    machine_id: str
    aisle_code: str
    final_action: str
    rate_limit_truncated: bool
    truncation_reason: str | None


class DeciderResult(TypedDict):
    plan_lines: list[FinalPlanLine]
    truncated_lines: list[FinalPlanLine]
    run_id: str
    plan_date: str
    written_to_db: bool
    total_lines: int
    refill_lines: int
    swap_lines: int
    truncated_count: int
    total_units: int


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


# ── Helpers ──────────────────────────────────────────────────────────────────

def _fourteen_days_ago() -> str:
    return (date.today() - timedelta(days=14)).isoformat()


def _aisle_to_shelf(aisle_code: str) -> str:
    """Strip 'N-' prefix: '0-A08' → 'A08'."""
    return aisle_code.split("-", 1)[1] if "-" in aisle_code else aisle_code


def _swap_min_for_candidate(candidate: SwapCandidate) -> int:
    """Return swap quantity for the incoming product."""
    return 6 if candidate["attr_drink"] else 4


# ── Startup fetches ──────────────────────────────────────────────────────────

def _fetch_recent_changes(client: Client) -> set[tuple[str, str]]:
    """Returns set of (machine_name, shelf_code) changed in last 14 days (approved)."""
    resp = (
        client.table("refill_plan_output")
        .select("machine_name, shelf_code, plan_date, action")
        .in_("action", ["SWAP", "REMOVE", "ADD NEW", "ADD_NEW"])
        .gte("plan_date", _fourteen_days_ago())
        .eq("operator_status", "approved")
        .limit(10000)
        .execute()
    )
    return {(r["machine_name"], r["shelf_code"]) for r in (resp.data or [])}


def _fetch_boonz_name_map(client: Client) -> dict[str, list[str]]:
    """
    Returns pod_product_id → list[boonz_product_name] (is_global_default=True only).
    Used for boonz_product_name resolution.
    """
    mapping_resp = (
        client.table("product_mapping")
        .select("pod_product_id, boonz_product_id")
        .eq("is_global_default", True)
        .limit(10000)
        .execute()
    )
    mapping_rows = mapping_resp.data or []

    bids = list({r["boonz_product_id"] for r in mapping_rows if r.get("boonz_product_id")})
    if not bids:
        return {}

    boonz_resp = (
        client.table("boonz_products")
        .select("product_id, boonz_product_name")
        .in_("product_id", bids)
        .limit(10000)
        .execute()
    )
    bid_to_name: dict[str, str] = {
        r["product_id"]: r["boonz_product_name"]
        for r in (boonz_resp.data or [])
        if r.get("boonz_product_name")
    }

    result: dict[str, list[str]] = {}
    for row in mapping_rows:
        ppid = row.get("pod_product_id")
        bid = row.get("boonz_product_id")
        name = bid_to_name.get(bid) if bid else None
        if ppid and name:
            result.setdefault(ppid, []).append(name)
    return result


def _resolve_boonz_name(
    pod_product_id: str | None,
    pod_product_name: str,
    boonz_name_map: dict[str, list[str]],
) -> tuple[str, str | None]:
    """
    Returns (boonz_product_name, variant_comment | None).

    Resolution rules:
      0 variants → boonz_product_name = pod_product_name
      1 variant  → boonz_product_name = that variant's name
      2+ variants → boonz_product_name = "{pod_product_name} Mix"
                    variant_comment = "Variants: {names}"
    """
    if not pod_product_id:
        return pod_product_name, None
    variants = boonz_name_map.get(pod_product_id, [])
    if not variants:
        return pod_product_name, None
    if len(variants) == 1:
        return variants[0], None
    return f"{pod_product_name} Mix", f"Variants: {', '.join(variants)}"


# ── Rate limit application ────────────────────────────────────────────────────

class _SwapCandidate:
    """Internal wrapper for a swap-eligible Engine B line + Engine C proposal."""
    __slots__ = ("line", "proposal", "priority", "shelf_code", "was_recent")

    def __init__(
        self,
        line: SlotRefillLine,
        proposal: SlotSwapProposal | None,
        recent_changes: set[tuple[str, str]],
    ) -> None:
        self.line = line
        self.proposal = proposal
        shelf = _aisle_to_shelf(line["aisle_code"])
        self.shelf_code = shelf
        self.was_recent = (line["machine_name"], shelf) in recent_changes

        trigger = line["final_action"] if line["final_action"] == "DISCONTINUE" else "SWAP_MINIMUM"
        conf = (
            proposal["top_candidate"]["confidence_label"]
            if proposal and proposal["top_candidate"]
            else "LOW"
        )
        self.priority = _SWAP_PRIORITY.get((trigger, conf), 1)


def _apply_rate_limits(
    swap_candidates: list[_SwapCandidate],
) -> tuple[list[_SwapCandidate], list[tuple[_SwapCandidate, str]]]:
    """
    Returns (accepted, [(rejected, reason)]).
    Accepted list is in priority order (best first).
    """
    # Sort: highest priority first, then by machine to group them
    sorted_cands = sorted(swap_candidates, key=lambda c: c.priority, reverse=True)

    accepted: list[_SwapCandidate] = []
    rejected: list[tuple[_SwapCandidate, str]] = []

    # First pass: filter out recent changes (hard block)
    after_recent: list[_SwapCandidate] = []
    for cand in sorted_cands:
        if cand.was_recent:
            rejected.append((cand, "min_days_not_elapsed"))
        else:
            after_recent.append(cand)

    # Second pass: apply count limits greedily
    machines_with_changes: set[str] = set()
    changes_per_machine: dict[str, int] = {}
    total_changes = 0

    for cand in after_recent:
        mid = cand.line["machine_id"]

        # Limit 1: max_total_slot_changes_per_day
        if total_changes >= RATE_LIMITS["max_total_slot_changes_per_day"]:
            rejected.append((cand, "max_total_slot_changes_per_day"))
            continue

        # Limit 2: max_slot_changes_per_machine
        machine_count = changes_per_machine.get(mid, 0)
        if machine_count >= RATE_LIMITS["max_slot_changes_per_machine"]:
            rejected.append((cand, "max_slot_changes_per_machine"))
            continue

        # Limit 3: max_machines_with_changes_per_day
        if (
            mid not in machines_with_changes
            and len(machines_with_changes) >= RATE_LIMITS["max_machines_with_changes_per_day"]
        ):
            rejected.append((cand, "max_machines_with_changes_per_day"))
            continue

        # Accept
        accepted.append(cand)
        machines_with_changes.add(mid)
        changes_per_machine[mid] = machine_count + 1
        total_changes += 1

    return accepted, rejected


# ── Plan line builders ────────────────────────────────────────────────────────

def _build_refill_line(
    line: SlotRefillLine,
    boonz_name_map: dict[str, list[str]],
    cls_map: dict[tuple[str, str], ProductClassification],
    plan_date: str,
) -> FinalPlanLine:
    """Build a single REFILL FinalPlanLine."""
    boonz_name, variant_comment = _resolve_boonz_name(
        line["pod_product_id"], line["pod_product_name"], boonz_name_map
    )
    cls = cls_map.get((line["machine_id"], line["aisle_code"]))
    global_score = cls["global_score"] if cls else None

    comment_parts = [line["explanation"]]
    if variant_comment:
        comment_parts.append(variant_comment)
    comment = " | ".join(comment_parts)

    return FinalPlanLine(
        plan_date=plan_date,
        machine_name=line["machine_name"],
        machine_priority=0,          # filled in after all lines assembled
        shelf_code=_aisle_to_shelf(line["aisle_code"]),
        pod_product_name=line["pod_product_name"],
        boonz_product_name=boonz_name,
        action="REFILL",
        quantity=line["refill_qty"],
        current_stock=line["current_stock"],
        max_stock=line["effective_max_stock"],
        smart_target=line["target_qty"],
        global_score=global_score,
        fill_pct=None,
        comment=comment,
        operator_status="pending",
        machine_id=line["machine_id"],
        aisle_code=line["aisle_code"],
        final_action=line["final_action"],
        rate_limit_truncated=False,
        truncation_reason=None,
    )


def _build_swap_lines(
    cand: _SwapCandidate,
    boonz_name_map: dict[str, list[str]],
    cls_map: dict[tuple[str, str], ProductClassification],
    plan_date: str,
) -> list[FinalPlanLine]:
    """
    Build REMOVE + ADD NEW rows for an accepted swap candidate.
    Falls back to REMOVE-only if no top_candidate.
    Falls back to REFILL if is_swap_minimum with no candidate.
    """
    line = cand.line
    proposal = cand.proposal
    cls = cls_map.get((line["machine_id"], line["aisle_code"]))
    global_score = cls["global_score"] if cls else None
    shelf = cand.shelf_code
    trigger = "DISCONTINUE" if line["final_action"] == "DISCONTINUE" else "SWAP_MINIMUM"

    boonz_old, _ = _resolve_boonz_name(
        line["pod_product_id"], line["pod_product_name"], boonz_name_map
    )

    top = proposal["top_candidate"] if proposal else None

    if not top:
        if trigger == "SWAP_MINIMUM":
            # No candidate for swap_minimum → plain REFILL
            boonz_name, variant_comment = _resolve_boonz_name(
                line["pod_product_id"], line["pod_product_name"], boonz_name_map
            )
            comment = line["explanation"]
            if variant_comment:
                comment += f" | {variant_comment}"
            return [FinalPlanLine(
                plan_date=plan_date,
                machine_name=line["machine_name"],
                machine_priority=0,
                shelf_code=shelf,
                pod_product_name=line["pod_product_name"],
                boonz_product_name=boonz_name,
                action="REFILL",
                quantity=line["refill_qty"],
                current_stock=line["current_stock"],
                max_stock=line["effective_max_stock"],
                smart_target=line["target_qty"],
                global_score=global_score,
                fill_pct=None,
                comment=comment,
                operator_status="pending",
                machine_id=line["machine_id"],
                aisle_code=line["aisle_code"],
                final_action=line["final_action"],
                rate_limit_truncated=False,
                truncation_reason=None,
            )]
        else:
            # DISCONTINUE, no candidate → lone REMOVE
            remove_comment = "Engine D: removing — no replacement candidate available"
            if cls:
                remove_comment = f"Engine D: removing — {cls['explanation']}"
            return [FinalPlanLine(
                plan_date=plan_date,
                machine_name=line["machine_name"],
                machine_priority=0,
                shelf_code=shelf,
                pod_product_name=line["pod_product_name"],
                boonz_product_name=boonz_old,
                action="REMOVE",
                quantity=0,
                current_stock=line["current_stock"],
                max_stock=line["effective_max_stock"],
                smart_target=0,
                global_score=global_score,
                fill_pct=None,
                comment=remove_comment,
                operator_status="pending",
                machine_id=line["machine_id"],
                aisle_code=line["aisle_code"],
                final_action=line["final_action"],
                rate_limit_truncated=False,
                truncation_reason=None,
            )]

    # Has a top_candidate → REMOVE + ADD NEW
    boonz_new, variant_comment_new = _resolve_boonz_name(
        top["pod_product_id"], top["pod_product_name"], boonz_name_map
    )
    swap_qty = _swap_min_for_candidate(top)

    remove_comment = (
        f"Engine D: removing — {cls['explanation']}"
        if cls else "Engine D: removing — no lifecycle data"
    )
    add_comment = f"Engine C: {top['reason']} (conf={top['confidence_label']})"
    if variant_comment_new:
        add_comment += f" | {variant_comment_new}"

    remove_row = FinalPlanLine(
        plan_date=plan_date,
        machine_name=line["machine_name"],
        machine_priority=0,
        shelf_code=shelf,
        pod_product_name=line["pod_product_name"],
        boonz_product_name=boonz_old,
        action="REMOVE",
        quantity=0,
        current_stock=line["current_stock"],
        max_stock=line["effective_max_stock"],
        smart_target=0,
        global_score=global_score,
        fill_pct=None,
        comment=remove_comment,
        operator_status="pending",
        machine_id=line["machine_id"],
        aisle_code=line["aisle_code"],
        final_action=line["final_action"],
        rate_limit_truncated=False,
        truncation_reason=None,
    )
    add_row = FinalPlanLine(
        plan_date=plan_date,
        machine_name=line["machine_name"],
        machine_priority=0,
        shelf_code=shelf,
        pod_product_name=top["pod_product_name"],
        boonz_product_name=boonz_new,
        action="ADD NEW",
        quantity=swap_qty,
        current_stock=0,
        max_stock=line["effective_max_stock"],
        smart_target=swap_qty,
        global_score=top["global_score"],
        fill_pct=None,
        comment=add_comment,
        operator_status="pending",
        machine_id=line["machine_id"],
        aisle_code=line["aisle_code"],
        final_action=line["final_action"],
        rate_limit_truncated=False,
        truncation_reason=None,
    )
    return [remove_row, add_row]


# ── Machine priority assignment ───────────────────────────────────────────────

def _assign_machine_priorities(lines: list[FinalPlanLine]) -> None:
    """Rank machines by total refill_qty descending. Mutates lines in-place."""
    machine_units: dict[str, int] = {}
    for line in lines:
        mid = line["machine_id"]
        machine_units[mid] = machine_units.get(mid, 0) + line["quantity"]

    ranked = sorted(machine_units.items(), key=lambda kv: kv[1], reverse=True)
    priority_map = {mid: rank + 1 for rank, (mid, _) in enumerate(ranked)}

    for line in lines:
        line["machine_priority"] = priority_map.get(line["machine_id"], 99)


# ── DB write helpers ──────────────────────────────────────────────────────────

_DB_FIELDS = (
    "plan_date", "machine_name", "machine_priority", "shelf_code",
    "pod_product_name", "boonz_product_name", "action", "quantity",
    "current_stock", "max_stock", "smart_target", "global_score",
    "fill_pct", "comment", "operator_status",
)


def _to_db_row(line: FinalPlanLine) -> dict:
    """Extract only the DB-writable fields from a FinalPlanLine."""
    row = {f: line[f] for f in _DB_FIELDS}  # type: ignore[literal-required]
    # Coerce None floats to None (Supabase accepts null for numeric columns)
    if row["global_score"] is not None:
        row["global_score"] = float(row["global_score"])
    return row


def _chunked_insert(client: Client, table: str, rows: list[dict], chunk: int = 50) -> None:
    for i in range(0, len(rows), chunk):
        client.table(table).insert(rows[i : i + chunk]).execute()


def _write_plan(client: Client, plan_date: str, lines: list[FinalPlanLine]) -> None:
    """Idempotent: delete today's pending plan, then insert new lines."""
    client.table("refill_plan_output").delete().eq("plan_date", plan_date).eq(
        "operator_status", "pending"
    ).execute()

    db_rows = [_to_db_row(line) for line in lines]
    _chunked_insert(client, "refill_plan_output", db_rows)


def _write_decision_log(
    client: Client,
    run_id: str,
    result: "DeciderResult",
    truncated_cands: list[tuple[_SwapCandidate, str]],
    fleet: FleetState,
) -> None:
    """Write one summary row + one row per truncated line to decision_log."""
    machine_names = sorted({line["machine_name"] for line in result["plan_lines"]})

    summary_row = {
        "run_id": run_id,
        "engine_name": "engine_d",
        "machine_id": None,
        "pod_product_id": None,
        "inputs_json": {
            "refill_lines": result["refill_lines"],
            "swap_lines": result["swap_lines"],
            "rate_limits": RATE_LIMITS,
            "truncated_count": result["truncated_count"],
        },
        "decision_json": {
            "plan_date": result["plan_date"],
            "total_lines": result["total_lines"],
            "total_units": result["total_units"],
            "machines_in_plan": machine_names,
        },
    }
    client.table("decision_log").insert(summary_row).execute()

    for cand, reason in truncated_cands:
        line = cand.line
        machine_meta = fleet["machines"].get(line["machine_id"])
        machine_uuid = line["machine_id"] if machine_meta else None
        trigger = (
            "DISCONTINUE" if line["final_action"] == "DISCONTINUE" else "SWAP_MINIMUM"
        )
        top = cand.proposal["top_candidate"] if cand.proposal else None
        conf_label = top["confidence_label"] if top else "N/A"

        trunc_row = {
            "run_id": run_id,
            "engine_name": "engine_d",
            "machine_id": machine_uuid,
            "pod_product_id": line.get("pod_product_id"),
            "inputs_json": {
                "shelf_code": cand.shelf_code,
                "pod_product_name": line["pod_product_name"],
                "confidence_label": conf_label,
                "swap_trigger": trigger,
            },
            "decision_json": {
                "reason": "rate_limit_exceeded",
                "rate_limit_hit": reason,
            },
        }
        client.table("decision_log").insert(trunc_row).execute()


# ── Main entry point ──────────────────────────────────────────────────────────

def run_engine_d(
    fleet: FleetState,
    portfolio: PortfolioResult,
    refill_plan: RefillPlan,
    swap_plan: SwapPlan,
    dry_run: bool = True,
) -> DeciderResult:
    """
    Compute final refill plan, apply rate limits, optionally write to DB.

    dry_run=True (default): build and return plan, do NOT write to Supabase.
    dry_run=False: write to refill_plan_output and decision_log.
    """
    client = _get_client()
    run_id = str(uuid.uuid4())
    plan_date = (date.today() + timedelta(days=1)).isoformat()

    # ── Startup fetches ────────────────────────────────────────────────────
    recent_changes = _fetch_recent_changes(client)
    boonz_name_map = _fetch_boonz_name_map(client)

    # ── Build lookup maps ──────────────────────────────────────────────────
    cls_map: dict[tuple[str, str], ProductClassification] = {
        (c["machine_id"], c["aisle_code"]): c
        for c in portfolio["classifications"]
    }

    proposal_map: dict[tuple[str, str], SlotSwapProposal] = {
        (p["machine_id"], p["aisle_code"]): p
        for p in swap_plan["proposals"]
    }

    # ── Separate lines into REFILL vs swap-eligible ────────────────────────
    refill_b_lines: list[SlotRefillLine] = []
    swap_b_lines: list[SlotRefillLine] = []

    for line in refill_plan["lines"]:
        is_swap_eligible = (
            line["final_action"] == "DISCONTINUE" or line["is_swap_minimum"]
        )
        if is_swap_eligible:
            swap_b_lines.append(line)
        elif line["refill_qty"] > 0:
            refill_b_lines.append(line)
        # else: refill_qty == 0, not DISCONTINUE → skip

    # ── Apply rate limits to swap lines ───────────────────────────────────
    swap_wrapped = [
        _SwapCandidate(line, proposal_map.get((line["machine_id"], line["aisle_code"])), recent_changes)
        for line in swap_b_lines
    ]
    accepted_swaps, rejected_swaps = _apply_rate_limits(swap_wrapped)

    # ── Build REFILL final plan lines ──────────────────────────────────────
    final_lines: list[FinalPlanLine] = []
    for line in refill_b_lines:
        final_lines.append(
            _build_refill_line(line, boonz_name_map, cls_map, plan_date)
        )

    # ── Build SWAP final plan lines ────────────────────────────────────────
    swap_line_count = 0  # count of REMOVE+ADD NEW pairs / lone REMOVEs
    for cand in accepted_swaps:
        rows = _build_swap_lines(cand, boonz_name_map, cls_map, plan_date)
        final_lines.extend(rows)
        # Count as swap only if we actually wrote a REMOVE or ADD NEW
        if any(r["action"] in ("REMOVE", "ADD NEW") for r in rows):
            swap_line_count += 1

    # ── Build truncated list ───────────────────────────────────────────────
    truncated_lines: list[FinalPlanLine] = []
    for cand, reason in rejected_swaps:
        rows = _build_swap_lines(cand, boonz_name_map, cls_map, plan_date)
        for r in rows:
            r["rate_limit_truncated"] = True
            r["truncation_reason"] = reason
        truncated_lines.extend(rows)

    # ── Assign machine priorities ──────────────────────────────────────────
    _assign_machine_priorities(final_lines)

    total_units = sum(line["quantity"] for line in final_lines)
    refill_count = sum(1 for line in final_lines if line["action"] == "REFILL")

    result = DeciderResult(
        plan_lines=final_lines,
        truncated_lines=truncated_lines,
        run_id=run_id,
        plan_date=plan_date,
        written_to_db=False,
        total_lines=len(final_lines),
        refill_lines=refill_count,
        swap_lines=swap_line_count,
        truncated_count=len(rejected_swaps),
        total_units=total_units,
    )

    # ── DB writes (only if not dry_run) ───────────────────────────────────
    if not dry_run:
        _write_plan(client, plan_date, final_lines)
        _write_decision_log(client, run_id, result, rejected_swaps, fleet)
        result["written_to_db"] = True

    return result


# ── Full pipeline entry point ─────────────────────────────────────────────────

def run_pipeline(dry_run: bool = True) -> DeciderResult:
    """
    Full pipeline: fetch → Engine 1 → B → C → D.
    Single entry point for the complete refill brain.
    """
    print("Fetching fleet state...")
    fleet = fetch_fleet_state()

    print("Running Engine 1 (portfolio)...")
    portfolio = run_engine_1(fleet)

    print("Running Engine B (quantity)...")
    refill_plan = run_engine_b(fleet, portfolio)

    print("Running Engine C (swap)...")
    swap_plan = run_engine_c(fleet, portfolio, refill_plan)

    print("Running Engine D (decider)...")
    return run_engine_d(fleet, portfolio, refill_plan, swap_plan, dry_run=dry_run)


# ── CLI smoke test (dry_run=True — never writes) ──────────────────────────────

if __name__ == "__main__":
    print("=== BOONZ REFILL BRAIN — Full Pipeline ===")

    print("Fetching fleet state...", end="      ", flush=True)
    _fleet = fetch_fleet_state()
    print(f"✓ {_fleet['machine_count']} machines, {_fleet['slot_count']} slots")

    print("Running Engine 1...", end="          ", flush=True)
    _portfolio = run_engine_1(_fleet)
    print(
        f"✓ {_portfolio['slot_count']} classified "
        f"({_portfolio['double_down_count']} DOUBLE_DOWN, "
        f"{_portfolio['keep_count']} KEEP, "
        f"{_portfolio['monitor_count']} MONITOR, "
        f"{_portfolio['discontinue_count']} DISCONTINUE)"
    )

    print("Running Engine B...", end="          ", flush=True)
    _refill_plan = run_engine_b(_fleet, _portfolio)
    total_b = sum(l["refill_qty"] for l in _refill_plan["lines"])
    to_refill_b = sum(1 for l in _refill_plan["lines"] if l["refill_qty"] > 0)
    print(f"✓ {total_b} units across {to_refill_b} slots")

    print("Running Engine C...", end="          ", flush=True)
    _swap_plan = run_engine_c(_fleet, _portfolio, _refill_plan)
    print(
        f"✓ {_swap_plan['eligible_slots']} swap proposals, "
        f"{_swap_plan['slots_without_candidates']} without candidates"
    )

    import sys
    _dry = "--live" not in sys.argv

    print(f"Running Engine D ({'DRY RUN' if _dry else 'LIVE — writing to Supabase'})...")

    _result = run_engine_d(_fleet, _portfolio, _refill_plan, _swap_plan, dry_run=_dry)

    # Rate limit summary
    print()
    print("Rate limit check:")
    _client_tmp = _get_client()
    _recent = _fetch_recent_changes(_client_tmp)
    print(f"  Recent changes (14d): {len(_recent)} slots already changed — ineligible")

    # Count swap lines proposed before limits
    _swap_proposed = sum(
        1 for l in _refill_plan["lines"]
        if l["final_action"] == "DISCONTINUE" or l["is_swap_minimum"]
    )
    print(f"  Swap lines proposed : {_swap_proposed}")
    print(
        f"  After rate limits   : {_result['swap_lines']} "
        f"({_result['truncated_count']} truncated)"
    )

    print()
    plan_date_display = _result["plan_date"]
    print(f"=== FINAL PLAN [{'DRY RUN — NOT WRITTEN' if _dry else 'LIVE — WRITTEN TO SUPABASE'}] ===")
    print(f"Plan date : {plan_date_display}")

    # Count by machine
    machines_in_plan = {l["machine_name"] for l in _result["plan_lines"]}
    print(f"Machines  : {len(machines_in_plan)}")

    refill_count = sum(1 for l in _result["plan_lines"] if l["action"] == "REFILL")
    remove_count = sum(1 for l in _result["plan_lines"] if l["action"] == "REMOVE")
    add_count    = sum(1 for l in _result["plan_lines"] if l["action"] == "ADD NEW")
    swap_pairs   = min(remove_count, add_count)  # pairs with both rows
    lone_removes = remove_count - swap_pairs

    print(f"REFILL    : {refill_count} lines")
    print(f"SWAP      : {swap_pairs} pairs (REMOVE + ADD NEW)")
    print(f"REMOVE    : {lone_removes} lines (no candidate)")
    print(f"Total units: {_result['total_units']}")

    # By machine, sorted by total units
    print()
    print("By machine (sorted by total units):")
    machine_summary: dict[str, dict] = {}
    for line in _result["plan_lines"]:
        mn = line["machine_name"]
        if mn not in machine_summary:
            machine_summary[mn] = {"units": 0, "swaps": 0}
        machine_summary[mn]["units"] += line["quantity"]
        if line["action"] in ("REMOVE", "ADD NEW"):
            machine_summary[mn]["swaps"] += 1

    for mn, stats in sorted(machine_summary.items(), key=lambda kv: kv[1]["units"], reverse=True):
        swap_str = f", {stats['swaps']//2} swap pair{'s' if stats['swaps']//2 != 1 else ''}" if stats["swaps"] else ""
        print(f"  {mn:<30} — {stats['units']} units{swap_str}")

    # Truncated lines
    print()
    print(f"Truncated by rate limits: {_result['truncated_count']} swap slots")
    if _result["truncated_lines"]:
        seen_truncated: set[tuple[str, str]] = set()
        for tl in _result["truncated_lines"]:
            key = (tl["machine_name"], tl["shelf_code"])
            if key in seen_truncated:
                continue
            seen_truncated.add(key)
            print(
                f"  [{tl['machine_name'][:24]:<24}] "
                f"{tl['shelf_code']:<6} "
                f"{tl['pod_product_name'][:25]:<25} "
                f"— {tl['truncation_reason']}"
            )

    print()
    if _dry:
        print(f"[DRY RUN] Pass --live flag to write to Supabase.")
    else:
        print(f"[LIVE] Plan written to refill_plan_output — operator_status='pending'.")
