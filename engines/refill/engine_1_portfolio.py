"""
engine_1_portfolio.py
Engine 1 — Portfolio Manager.

Reads two layers:
  DATA:     product_lifecycle_global + slot_lifecycle (Supabase)
  GUARDRAIL: engines/refill/guardrails/portfolio_strategy.md (file)

Reconciles them → per-slot ProductClassification.
Returns PortfolioResult consumed by Engine B and Engine C.
Does NOT write to the DB.
"""

from __future__ import annotations

import os
import re
import warnings
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import TypedDict

from dotenv import load_dotenv
from supabase import create_client, Client

try:
    from engines.refill.subskills.fetch_fleet_state import (
        FleetState,
        SlotState,
        MachineMetadata,
    )
except ImportError:
    from subskills.fetch_fleet_state import FleetState, SlotState, MachineMetadata  # type: ignore

load_dotenv()


# ── Constants ──────────────────────────────────────────────────────────────

_GUARDRAIL_FILE = Path(__file__).parent / "guardrails" / "portfolio_strategy.md"

# Travel-scope VOX-locked products (hardcoded per spec — do NOT parse travel-scope.md here)
VOX_LOCKED_PRODUCTS: frozenset[str] = frozenset(
    {
        "Aquafina",
        "Maltesers Chocolate Bag",
        "M&M Chocolate Bag",
        "Skittles Bag",
        "VOX Popcorn Caramel",
        "VOX Popcorn Cheese",
        "VOX Popcorn Salt",
        "VOX Lollies",
        "VOX Cotton Candy",
    }
)

# Signal → action mapping for (global_signal, slot_signal) pairs.
# slot_signal=None → only global row available.
_SIGNAL_MAP: dict[tuple[str, str | None], str] = {
    # global KEEP GROWING → always DOUBLE_DOWN
    ("KEEP GROWING", None): "DOUBLE_DOWN",
    ("KEEP GROWING", "KEEP GROWING"): "DOUBLE_DOWN",
    ("KEEP GROWING", "KEEP"): "DOUBLE_DOWN",
    ("KEEP GROWING", "WATCH"): "DOUBLE_DOWN",
    ("KEEP GROWING", "WIND DOWN"): "DOUBLE_DOWN",
    ("KEEP GROWING", "ROTATE OUT"): "DOUBLE_DOWN",
    # global KEEP
    ("KEEP", None): "KEEP",
    ("KEEP", "KEEP GROWING"): "KEEP",
    ("KEEP", "KEEP"): "KEEP",
    ("KEEP", "WATCH"): "KEEP",
    ("KEEP", "WIND DOWN"): "MONITOR",
    ("KEEP", "ROTATE OUT"): "DISCONTINUE",
    # global WATCH (treated as borderline KEEP)
    ("WATCH", None): "MONITOR",
    ("WATCH", "KEEP GROWING"): "KEEP",
    ("WATCH", "KEEP"): "KEEP",
    ("WATCH", "WATCH"): "MONITOR",
    ("WATCH", "WIND DOWN"): "MONITOR",
    ("WATCH", "ROTATE OUT"): "DISCONTINUE",
    # global WIND DOWN
    ("WIND DOWN", None): "MONITOR",
    ("WIND DOWN", "KEEP GROWING"): "MONITOR",
    ("WIND DOWN", "KEEP"): "MONITOR",
    ("WIND DOWN", "WATCH"): "MONITOR",
    ("WIND DOWN", "WIND DOWN"): "MONITOR",
    ("WIND DOWN", "ROTATE OUT"): "DISCONTINUE",
    # global ROTATE OUT → always DISCONTINUE
    ("ROTATE OUT", None): "DISCONTINUE",
    ("ROTATE OUT", "KEEP GROWING"): "DISCONTINUE",
    ("ROTATE OUT", "KEEP"): "DISCONTINUE",
    ("ROTATE OUT", "WATCH"): "DISCONTINUE",
    ("ROTATE OUT", "WIND DOWN"): "DISCONTINUE",
    ("ROTATE OUT", "ROTATE OUT"): "DISCONTINUE",
}

# Global-only fallback (when slot row missing)
_GLOBAL_FALLBACK: dict[str, str] = {
    "KEEP GROWING": "DOUBLE_DOWN",
    "KEEP": "KEEP",
    "WATCH": "MONITOR",
    "WIND DOWN": "MONITOR",
    "ROTATE OUT": "DISCONTINUE",
}


# ── Output types ───────────────────────────────────────────────────────────

class ProductClassification(TypedDict):
    machine_id: str
    aisle_code: str
    pod_product_id: str | None
    pod_product_name: str
    global_signal: str          # raw from product_lifecycle_global
    slot_signal: str | None     # raw from slot_lifecycle; None if row missing
    global_score: float
    slot_score: float | None
    base_action: str            # before guardrail overrides
    final_action: str           # DOUBLE_DOWN | KEEP | MONITOR | DISCONTINUE
    guardrail_override: str | None  # reason code if overridden, else None
    confidence: str             # HIGH | MEDIUM | LOW
    explanation: str            # 1-sentence plain English for operator


class PortfolioResult(TypedDict):
    classifications: list[ProductClassification]
    run_at: str
    slot_count: int
    guardrail_overrides: int
    discontinue_count: int
    double_down_count: int
    monitor_count: int
    keep_count: int


# ── Guardrail parser ───────────────────────────────────────────────────────

@dataclass
class _GuardrailData:
    """Parsed in-memory state from portfolio_strategy.md."""
    # Section 5: normalised_name_lower → (level, protected_until)
    protections: dict[str, tuple[str, str]] = field(default_factory=dict)
    # Section 6: brand_pattern_lower → bias (SOFT | HARD)
    phase_outs: dict[str, str] = field(default_factory=dict)


def _parse_md_table_rows(lines: list[str]) -> list[list[str]]:
    """
    Extract data rows from a contiguous block of markdown table lines.
    Skips the header and separator rows. Returns list of cell-lists.
    """
    rows: list[list[str]] = []
    header_done = False
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("|"):
            break
        cells = [c.strip().strip("`") for c in stripped.split("|")[1:-1]]
        if not header_done:
            header_done = True
            continue  # skip header row
        if all(re.match(r"^-+$", c.replace(" ", "")) for c in cells if c):
            continue  # skip separator row
        rows.append(cells)
    return rows


def _collect_table_lines(all_lines: list[str], start: int) -> list[str]:
    """From start index, return lines that belong to the next markdown table."""
    result: list[str] = []
    in_table = False
    for line in all_lines[start:start + 60]:
        if line.strip().startswith("|"):
            in_table = True
            result.append(line)
        elif in_table:
            break
    return result


def _parse_guardrails() -> _GuardrailData:
    """
    Parse portfolio_strategy.md. Extract Section 5.3 and Section 6.4 tables.
    Re-parsed every call — no caching — so file edits take effect without restart.
    Raises FileNotFoundError if the file is missing.
    Warns (never crashes) on unrecognised entries.
    """
    if not _GUARDRAIL_FILE.exists():
        raise FileNotFoundError(
            f"Guardrail file missing: {_GUARDRAIL_FILE}. "
            "Run from the repo root and ensure engines/refill/guardrails/ exists."
        )

    lines = _GUARDRAIL_FILE.read_text(encoding="utf-8").splitlines()
    gd = _GuardrailData()

    sec5_idx: int | None = None
    sec6_idx: int | None = None
    for i, line in enumerate(lines):
        if re.search(r"#+\s+5\.3\s+Active protections table", line, re.IGNORECASE):
            sec5_idx = i
        if re.search(r"#+\s+6\.4\s+Active phase.out candidates table", line, re.IGNORECASE):
            sec6_idx = i

    # ── Section 5.3 protections ────────────────────────────────────────────
    if sec5_idx is not None:
        table_lines = _collect_table_lines(lines, sec5_idx)
        for cells in _parse_md_table_rows(table_lines):
            if len(cells) < 3:
                continue
            raw_name = cells[0].strip("_()")
            raw_level = cells[2].strip("`").upper()
            raw_until = cells[3].strip() if len(cells) > 3 else "Indefinite"

            # Skip the meta pointer row for VOX-locked products
            # (handled via hardcoded VOX_LOCKED_PRODUCTS set)
            if "vox-locked" in raw_name.lower() or raw_name.startswith("_"):
                continue
            if not raw_name or raw_level not in (
                "CONTRACTUAL", "CLIENT_REQUEST", "OPERATOR_WATCH"
            ):
                if raw_name:
                    warnings.warn(
                        f"Engine 1 guardrail parser: unrecognised protection level "
                        f"'{raw_level}' for '{raw_name}' — skipping."
                    )
                continue
            gd.protections[raw_name.lower()] = (raw_level, raw_until)

    # ── Section 6.4 phase-out candidates ──────────────────────────────────
    if sec6_idx is not None:
        table_lines = _collect_table_lines(lines, sec6_idx)
        for cells in _parse_md_table_rows(table_lines):
            if len(cells) < 2:
                continue
            raw_name = cells[0].strip()
            raw_bias = cells[1].strip("`").upper()

            if not raw_name:
                continue
            if raw_bias not in ("SOFT", "HARD", "NONE"):
                warnings.warn(
                    f"Engine 1 guardrail parser: unrecognised phase-out bias "
                    f"'{raw_bias}' for '{raw_name}' — skipping."
                )
                continue
            if raw_bias == "NONE":
                continue
            # Normalise brand name: "7days (brand, all SKUs)" → "7days"
            brand = re.split(r"\s*\(", raw_name)[0].strip().lower()
            if brand:
                gd.phase_outs[brand] = raw_bias

    return gd


# ── DB client ──────────────────────────────────────────────────────────────

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


# ── Lifecycle data fetcher ─────────────────────────────────────────────────

def _fetch_lifecycle_data(client: Client) -> tuple[
    dict[str, dict],   # plg: pod_product_id → row
    dict[tuple[str, str], dict],  # slot_lc: (machine_id, shelf_code) → row
]:
    """
    Fetch product_lifecycle_global and slot_lifecycle in parallel.
    slot_lc keyed by (machine_id, shelf_code) — note: shelf_code format is "A04",
    while v_live_shelf_stock.aisle_code is "0-A04". Strip leading "N-" before joining.
    """
    def _plg() -> dict[str, dict]:
        resp = (
            client.table("product_lifecycle_global")
            .select(
                "pod_product_id, score, signal, trend_component, "
                "machine_count, total_velocity_30d, last_evaluated_at"
            )
            .limit(10000)
            .execute()
        )
        return {r["pod_product_id"]: r for r in resp.data}

    def _slot_lc() -> dict[tuple[str, str], dict]:
        resp = (
            client.table("slot_lifecycle")
            .select(
                "machine_id, shelf_code, pod_product_id, score, signal, "
                "velocity_30d, slot_age_days, recommended_pod_product_id, "
                "recommendation_reason"
            )
            .eq("archived", False)
            .limit(10000)
            .execute()
        )
        return {(r["machine_id"], r["shelf_code"]): r for r in resp.data}

    results: dict[str, object] = {}
    errors: list[str] = []

    with ThreadPoolExecutor(max_workers=2) as ex:
        futures = {ex.submit(_plg): "plg", ex.submit(_slot_lc): "slot_lc"}
        for fut in as_completed(futures):
            name = futures[fut]
            try:
                results[name] = fut.result()
            except Exception as exc:
                errors.append(f"{name}: {exc}")

    if errors:
        raise RuntimeError(f"_fetch_lifecycle_data failed: {'; '.join(errors)}")

    return results["plg"], results["slot_lc"]  # type: ignore[return-value]


# ── Signal mapping ─────────────────────────────────────────────────────────

def _map_to_base_action(global_signal: str, slot_signal: str | None) -> str:
    """Map (global_signal, slot_signal) → base action string."""
    g = (global_signal or "KEEP").upper().strip()
    s = slot_signal.upper().strip() if slot_signal else None
    action = _SIGNAL_MAP.get((g, s))
    if action:
        return action
    # Fallback: unmapped combination → use global signal alone
    return _GLOBAL_FALLBACK.get(g, "MONITOR")


# ── Override engine ────────────────────────────────────────────────────────

def _apply_overrides(
    base_action: str,
    pod_product_name: str,
    venue_group: str | None,
    gd: _GuardrailData,
) -> tuple[str, str | None]:
    """
    Apply guardrail overrides in priority order:
      C. VOX travel restriction
      A. Protection (CONTRACTUAL / CLIENT_REQUEST / OPERATOR_WATCH)
      B. Phase-out bias (HARD → action change, SOFT → flag only)

    Returns (final_action, guardrail_override_code | None).
    """
    name_lower = pod_product_name.lower().strip()
    is_vox_machine = (venue_group or "").upper() == "VOX"

    # Exact or substring match against VOX_LOCKED_PRODUCTS
    is_vox_product = any(
        vp.lower() == name_lower or vp.lower() in name_lower
        for vp in VOX_LOCKED_PRODUCTS
    )

    # ── C. VOX travel restriction ──────────────────────────────────────────
    if is_vox_product and not is_vox_machine:
        return "DISCONTINUE", "VOX_RESTRICTED"

    # ── A. Implicit CONTRACTUAL protection for VOX-locked on VOX machine ──
    if is_vox_product and is_vox_machine:
        if base_action in ("DISCONTINUE", "MONITOR"):
            return "KEEP", "PROTECTED_CONTRACTUAL"
        # Already KEEP / DOUBLE_DOWN — just annotate
        return base_action, "PROTECTED_CONTRACTUAL"

    # ── A. Explicit protections from Section 5.3 ─────────────────────────
    for pattern, (level, _until) in gd.protections.items():
        if pattern in name_lower:
            if level in ("CONTRACTUAL", "CLIENT_REQUEST"):
                if base_action in ("DISCONTINUE", "MONITOR"):
                    return "KEEP", f"PROTECTED_{level}"
                return base_action, f"PROTECTED_{level}"
            if level == "OPERATOR_WATCH":
                return base_action, "OPERATOR_WATCH"

    # ── B. Phase-out bias from Section 6.4 ───────────────────────────────
    for brand_pattern, bias in gd.phase_outs.items():
        if brand_pattern in name_lower:
            if bias == "HARD":
                if base_action == "KEEP":
                    return "MONITOR", "PHASEOUT_HARD"
                if base_action == "MONITOR":
                    return "DISCONTINUE", "PHASEOUT_HARD"
                # DOUBLE_DOWN or already DISCONTINUE
                return base_action, "PHASEOUT_HARD"
            if bias == "SOFT":
                return base_action, "PHASEOUT_SOFT"

    return base_action, None


# ── Confidence scoring ─────────────────────────────────────────────────────

def _compute_confidence(
    global_signal: str,
    slot_signal: str | None,
    global_score: float,
    guardrail_override: str | None,
) -> str:
    """
    HIGH   — both signals agree AND global_score > 5
    MEDIUM — signals agree but score ≤ 5, OR signals disagree but guardrail is clear
    LOW    — signals disagree AND no guardrail, OR slot missing AND score in 4–6
    """
    def _direction(sig: str) -> str:
        s = sig.upper()
        if s == "KEEP GROWING":
            return "up"
        if s in ("KEEP", "WATCH"):
            return "neutral"
        return "down"

    if slot_signal is None:
        # No slot lifecycle data
        if 4.0 <= global_score <= 6.0:
            return "LOW"
        return "MEDIUM"

    agree = _direction(global_signal) == _direction(slot_signal)
    if agree and global_score > 5.0:
        return "HIGH"
    if agree:
        return "MEDIUM"
    # Signals disagree
    if guardrail_override:
        return "MEDIUM"
    return "LOW"


# ── Explanation generator ──────────────────────────────────────────────────

_ACTION_PHRASES = {
    "DOUBLE_DOWN": "load to target and expand if possible",
    "KEEP": "maintain current placement",
    "MONITOR": "watch closely, no expansion",
    "DISCONTINUE": "remove from this machine",
}


def _explain(
    pod_product_name: str,
    global_signal: str,
    slot_signal: str | None,
    global_score: float,
    final_action: str,
    guardrail_override: str | None,
) -> str:
    """Return a 1-sentence plain-English explanation for the operator."""
    verb = _ACTION_PHRASES.get(final_action, final_action.lower())
    name = pod_product_name or "Unknown product"
    score_str = f"{global_score:.1f}"

    if guardrail_override == "VOX_RESTRICTED":
        return (
            f"{name} is VOX-restricted — only placed on VOX cinema machines; {verb}."
        )

    if guardrail_override and guardrail_override.startswith("PROTECTED_"):
        level_label = (
            guardrail_override.replace("PROTECTED_", "")
            .replace("_", " ")
            .title()
        )
        return (
            f"{name} protected ({level_label}) — kept despite "
            f"{global_signal.lower()} signal (score {score_str}); {verb}."
        )

    if guardrail_override == "OPERATOR_WATCH":
        return (
            f"{name} under operator watch — {global_signal} globally "
            f"(score {score_str}); {verb}."
        )

    if guardrail_override == "PHASEOUT_HARD":
        return (
            f"{name} hard phase-out flagged by operator — {verb} regardless of "
            f"{global_signal.lower()} signal."
        )

    if guardrail_override == "PHASEOUT_SOFT":
        slot_part = (
            f", slot {slot_signal.lower()}" if slot_signal else ""
        )
        return (
            f"{name} soft phase-out flagged — {global_signal} globally "
            f"(score {score_str}){slot_part}; monitoring, no forced action yet."
        )

    # Pure data path — no guardrail
    slot_part = (
        f", slot confirms {slot_signal.lower()}" if slot_signal else " (no slot data)"
    )
    return f"{name} {global_signal} globally (score {score_str}){slot_part} — {verb}."


# ── Main entry point ───────────────────────────────────────────────────────

def run_engine_1(fleet_state: FleetState) -> PortfolioResult:
    """
    Takes FleetState from fetch_fleet_state().
    Returns PortfolioResult with classification for every slot.

    Raises FileNotFoundError if portfolio_strategy.md is missing.
    Raises RuntimeError if DB reads fail.
    """
    client = _get_client()
    gd = _parse_guardrails()
    plg, slot_lc = _fetch_lifecycle_data(client)

    # Build machine venue_group lookup from fleet_state
    machine_venue: dict[str, str | None] = {
        mid: meta.get("venue_group")
        for mid, meta in fleet_state["machines"].items()
    }

    classifications: list[ProductClassification] = []

    for slot in fleet_state["slots"]:
        machine_id = slot["machine_id"]
        aisle_code = slot["aisle_code"]
        pod_product_id = slot.get("pod_product_id")
        product_name = slot.get("goods_name_raw") or ""

        # ── Data layer lookups ─────────────────────────────────────────────

        plg_row = plg.get(pod_product_id) if pod_product_id else None
        global_signal = (plg_row or {}).get("signal") or "KEEP"
        global_score = float((plg_row or {}).get("score") or 0.0)

        # shelf_code join: strip "N-" prefix from aisle_code → "A04"
        shelf_code = aisle_code.split("-", 1)[1] if "-" in aisle_code else aisle_code
        slot_lc_row = slot_lc.get((machine_id, shelf_code))
        slot_signal = (slot_lc_row or {}).get("signal") or None
        slot_score: float | None = (
            float(slot_lc_row["score"]) if slot_lc_row and slot_lc_row.get("score") is not None
            else None
        )

        # ── Signal mapping ─────────────────────────────────────────────────
        base_action = _map_to_base_action(global_signal, slot_signal)

        # ── Guardrail overrides ────────────────────────────────────────────
        venue_group = machine_venue.get(machine_id)
        final_action, guardrail_override = _apply_overrides(
            base_action, product_name, venue_group, gd
        )

        # ── Confidence + explanation ───────────────────────────────────────
        confidence = _compute_confidence(
            global_signal, slot_signal, global_score, guardrail_override
        )
        explanation = _explain(
            product_name, global_signal, slot_signal,
            global_score, final_action, guardrail_override
        )

        classifications.append(
            ProductClassification(
                machine_id=machine_id,
                aisle_code=aisle_code,
                pod_product_id=pod_product_id,
                pod_product_name=product_name,
                global_signal=global_signal,
                slot_signal=slot_signal,
                global_score=global_score,
                slot_score=slot_score,
                base_action=base_action,
                final_action=final_action,
                guardrail_override=guardrail_override,
                confidence=confidence,
                explanation=explanation,
            )
        )

    # ── Aggregate stats ────────────────────────────────────────────────────
    action_counts: dict[str, int] = {
        "DOUBLE_DOWN": 0, "KEEP": 0, "MONITOR": 0, "DISCONTINUE": 0
    }
    for c in classifications:
        action_counts[c["final_action"]] = action_counts.get(c["final_action"], 0) + 1

    return PortfolioResult(
        classifications=classifications,
        run_at=datetime.now(timezone.utc).isoformat(),
        slot_count=len(classifications),
        guardrail_overrides=sum(1 for c in classifications if c["guardrail_override"]),
        discontinue_count=action_counts.get("DISCONTINUE", 0),
        double_down_count=action_counts.get("DOUBLE_DOWN", 0),
        monitor_count=action_counts.get("MONITOR", 0),
        keep_count=action_counts.get("KEEP", 0),
    )


# ── CLI smoke test ─────────────────────────────────────────────────────────

if __name__ == "__main__":
    from engines.refill.subskills.fetch_fleet_state import fetch_fleet_state

    print("Engine 1 — Portfolio Manager")
    print("=" * 50)

    print("Step 1: Fetching fleet state...", end=" ", flush=True)
    fleet = fetch_fleet_state()
    print(f"✅  {fleet['machine_count']} machines, {fleet['slot_count']} slots")

    print("Step 2: Running Engine 1...", end=" ", flush=True)
    result = run_engine_1(fleet)
    print(f"✅  {result['slot_count']} classifications in {result['run_at']}")

    print()
    print("── Summary ──────────────────────────────────────")
    print(f"  DOUBLE_DOWN   : {result['double_down_count']:>4}")
    print(f"  KEEP          : {result['keep_count']:>4}")
    print(f"  MONITOR       : {result['monitor_count']:>4}")
    print(f"  DISCONTINUE   : {result['discontinue_count']:>4}")
    print(f"  Guardrail hits: {result['guardrail_overrides']:>4}")
    print()

    # Sample: one slot from each final_action bucket
    seen: set[str] = set()
    print("── Sample classifications ───────────────────────")
    for c in result["classifications"]:
        if c["final_action"] not in seen:
            seen.add(c["final_action"])
            print(
                f"  [{c['final_action']:<12}] "
                f"{c['pod_product_name'][:28]:<28} "
                f"conf={c['confidence']:<6} "
                f"override={c['guardrail_override'] or '—'}"
            )
            print(f"    ↳ {c['explanation']}")
        if len(seen) == 4:
            break

    # Guard: flag any slots without a lifecycle record (expected for new products)
    no_global = sum(1 for c in result["classifications"] if c["global_score"] == 0.0)
    if no_global:
        print()
        print(
            f"ℹ️  {no_global} slots have no product_lifecycle_global row "
            "(new products or unmatched). Defaulted to KEEP/MONITOR."
        )

    print()
    print("✅  Engine 1 smoke test complete.")
