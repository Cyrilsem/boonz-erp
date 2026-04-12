"""
engine_c_swap.py
Engine C — Swap Candidate Scorer (v1).

Scores replacement candidates for:
  1. DISCONTINUE slots  — product being removed, slot needs a replacement
  2. Swap-minimum slots — refill_qty > 0 but daily_avg == 0.0 (is_swap_minimum=True)

NOT in scope (v2): MONITOR slot upgrades. See bible v5.6 for v2 spec.

READ ONLY — no DB writes.
"""

from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timedelta, timezone
from typing import TypedDict

from dotenv import load_dotenv
from supabase import create_client, Client

try:
    from engines.refill.subskills.fetch_fleet_state import FleetState, fetch_fleet_state
    from engines.refill.engine_1_portfolio import PortfolioResult, run_engine_1
    from engines.refill.engine_b_quantity import RefillPlan, SlotRefillLine, run_engine_b
except ImportError:
    from subskills.fetch_fleet_state import FleetState, fetch_fleet_state  # type: ignore[no-redef]
    from engine_1_portfolio import PortfolioResult, run_engine_1            # type: ignore[no-redef]
    from engine_b_quantity import RefillPlan, SlotRefillLine, run_engine_b  # type: ignore[no-redef]

load_dotenv()


# ── Constants ────────────────────────────────────────────────────────────────

VOX_RESTRICTED: frozenset[str] = frozenset({
    "Aquafina",
    "Maltesers Chocolate Bag",
    "M&M Chocolate Bag",
    "Skittles Bag",
    "VOX Popcorn Caramel",
    "VOX Popcorn Cheese",
    "VOX Popcorn Salt",
    "VOX Lollies",
    "VOX Cotton Candy",
})

# Broad category groups — products in the same group are "same category"
_DRINK_CATEGORIES: frozenset[str] = frozenset({
    "Soft Drinks", "Water", "Sparkling Water", "Juice",
    "Iced Coffee & Tea", "Energy & Sports Drinks",
    "Vitamin & Health Drinks", "Protein Milk", "Infused Water",
})
_SNACK_CATEGORIES: frozenset[str] = frozenset({
    "Chips & Crisps", "Nuts & Dried Fruits", "Popcorn",
    "Crackers & Pretzels", "Dips & Crackers",
})
_SWEET_CATEGORIES: frozenset[str] = frozenset({
    "Chocolates", "Biscuits & Cookies", "Candy & Gummies",
    "Novelty Confectionery", "Cakes", "Pastries & Baked Goods",
    "Date Snacks", "Gum & Mints",
})
_HEALTHY_CATEGORIES: frozenset[str] = frozenset({
    "Protein & Health Bars", "Organic Rice Cake", "Healthy Biscuits",
})
_DAIRY_CATEGORIES: frozenset[str] = frozenset({
    "Dairy & Yogurt", "Pudding & Desserts",
})

_ALL_CATEGORY_GROUPS: tuple[frozenset[str], ...] = (
    _DRINK_CATEGORIES,
    _SNACK_CATEGORIES,
    _SWEET_CATEGORIES,
    _HEALTHY_CATEGORIES,
    _DAIRY_CATEGORIES,
)

# Minimum warehouse stock to be considered an eligible candidate
_MIN_WAREHOUSE_STOCK = 3
# Minimum days until expiry
_MIN_DAYS_TO_EXPIRY = 14


# ── Output types ─────────────────────────────────────────────────────────────

class SwapCandidate(TypedDict):
    pod_product_id: str
    pod_product_name: str
    global_score: float
    global_signal: str
    warehouse_stock: int        # total available units meeting criteria
    earliest_expiry: str | None # ISO date string
    confidence_score: float     # 0.0–1.0, Engine C's ranking score
    confidence_label: str       # HIGH / MEDIUM / LOW
    reason: str                 # 1 sentence explanation
    is_same_category: bool      # candidate category matches slot category
    attr_drink: bool            # for swap minimum sizing


class SlotSwapProposal(TypedDict):
    machine_id: str
    machine_name: str
    aisle_code: str
    slot_name: str
    current_product: str            # goods_name_raw being replaced
    current_pod_product_id: str | None
    swap_trigger: str               # 'DISCONTINUE' or 'SWAP_MINIMUM'
    candidates: list[SwapCandidate] # ranked best-first, max 3
    top_candidate: SwapCandidate | None
    no_candidate_reason: str | None


class SwapPlan(TypedDict):
    proposals: list[SlotSwapProposal]
    run_at: str
    eligible_slots: int
    slots_with_candidates: int
    slots_without_candidates: int
    total_candidates_scored: int


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


# ── Category helpers ─────────────────────────────────────────────────────────

def _category_group(category: str | None) -> frozenset[str] | None:
    """Return the broad group a category belongs to, or None."""
    if not category:
        return None
    for group in _ALL_CATEGORY_GROUPS:
        if category in group:
            return group
    return None


def _same_category(cat_a: str | None, cat_b: str | None) -> bool:
    """True if both categories fall in the same broad group."""
    if not cat_a or not cat_b:
        return False
    group_a = _category_group(cat_a)
    group_b = _category_group(cat_b)
    return group_a is not None and group_a is group_b


# ── Scoring ──────────────────────────────────────────────────────────────────

def score_candidate(
    candidate_global_score: float,
    is_same_category: bool,
    warehouse_stock: int,
    slot_age_days_of_best_performer: int,  # from slot_lifecycle if available
) -> float:
    """
    Returns a 0.0–1.0 confidence score for a swap candidate.
    slot_age_days_of_best_performer is accepted for future use but not yet
    factored into the v1 formula.
    """
    score = candidate_global_score / 10.0  # normalise base to 0-1

    if is_same_category:
        score += 0.15

    if warehouse_stock >= 50:
        score += 0.10
    elif warehouse_stock >= 20:
        score += 0.05

    return min(round(score, 3), 1.0)


def _confidence_label(score: float) -> str:
    if score >= 0.65:
        return "HIGH"
    if score >= 0.45:
        return "MEDIUM"
    return "LOW"


# ── Warehouse candidates fetch ───────────────────────────────────────────────

class _WarehouseCandidate(TypedDict):
    """Intermediate type: joined warehouse + product data, keyed by pod_product_id."""
    pod_product_id: str
    pod_product_name: str
    product_category: str | None
    attr_drink: bool
    total_stock: int
    earliest_expiry: str | None
    global_score: float
    global_signal: str


def _fetch_candidates_pool(client: Client) -> dict[str, _WarehouseCandidate]:
    """
    Fetch and join warehouse + product + lifecycle data in parallel.
    Returns dict keyed by pod_product_id with all fields needed for scoring.

    Join chain:
      warehouse_inventory → boonz_products (product_id)
      boonz_products → product_mapping (boonz_product_id, is_global_default=true)
      product_mapping → pod_products (pod_product_id)
      pod_products → product_lifecycle_global (pod_product_id)
    """
    expiry_cutoff = (date.today() + timedelta(days=_MIN_DAYS_TO_EXPIRY)).isoformat()

    def _fetch_wh() -> list[dict]:
        resp = (
            client.table("warehouse_inventory")
            .select("boonz_product_id, warehouse_stock, expiration_date, status")
            .eq("status", "Active")
            .gt("warehouse_stock", 0)
            .or_(f"expiration_date.is.null,expiration_date.gt.{expiry_cutoff}")
            .limit(10000)
            .execute()
        )
        return resp.data or []

    def _fetch_mapping() -> list[dict]:
        resp = (
            client.table("product_mapping")
            .select("pod_product_id, boonz_product_id")
            .eq("is_global_default", True)
            .limit(10000)
            .execute()
        )
        return resp.data or []

    def _fetch_pod_products() -> list[dict]:
        resp = (
            client.table("pod_products")
            .select("pod_product_id, pod_product_name, product_category")
            .limit(10000)
            .execute()
        )
        return resp.data or []

    def _fetch_boonz_products() -> list[dict]:
        resp = (
            client.table("boonz_products")
            .select("product_id, attr_drink")
            .limit(10000)
            .execute()
        )
        return resp.data or []

    def _fetch_plg() -> list[dict]:
        resp = (
            client.table("product_lifecycle_global")
            .select("pod_product_id, score, signal")
            .limit(10000)
            .execute()
        )
        return resp.data or []

    # Parallel fetch
    results: dict[str, object] = {}
    errors: list[str] = []
    fetchers = {
        "wh": _fetch_wh,
        "mapping": _fetch_mapping,
        "pod_products": _fetch_pod_products,
        "boonz_products": _fetch_boonz_products,
        "plg": _fetch_plg,
    }
    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = {executor.submit(fn): name for name, fn in fetchers.items()}
        for future in as_completed(futures):
            name = futures[future]
            try:
                results[name] = future.result()
            except Exception as exc:
                errors.append(f"{name}: {exc}")
    if errors:
        raise RuntimeError(f"_fetch_candidates_pool failed: {'; '.join(errors)}")

    wh_rows: list[dict]          = results["wh"]           # type: ignore[assignment]
    mapping_rows: list[dict]     = results["mapping"]       # type: ignore[assignment]
    pod_rows: list[dict]         = results["pod_products"]  # type: ignore[assignment]
    boonz_rows: list[dict]       = results["boonz_products"]# type: ignore[assignment]
    plg_rows: list[dict]         = results["plg"]           # type: ignore[assignment]

    # ── Step 1: aggregate warehouse by boonz_product_id ──────────────────
    # total_stock and earliest non-null expiry
    wh_agg: dict[str, dict] = {}
    for r in wh_rows:
        bid = r["boonz_product_id"]
        stock = float(r.get("warehouse_stock") or 0)
        expiry = r.get("expiration_date")
        if bid not in wh_agg:
            wh_agg[bid] = {"total_stock": 0.0, "earliest_expiry": None}
        wh_agg[bid]["total_stock"] += stock
        if expiry:
            prev = wh_agg[bid]["earliest_expiry"]
            if prev is None or expiry < prev:
                wh_agg[bid]["earliest_expiry"] = expiry

    # Filter: total_stock >= MIN_WAREHOUSE_STOCK
    eligible_bids = {
        bid for bid, agg in wh_agg.items()
        if agg["total_stock"] >= _MIN_WAREHOUSE_STOCK
    }

    # ── Step 2: build lookup maps ─────────────────────────────────────────
    # boonz_product_id → pod_product_id (global default only)
    bid_to_ppid: dict[str, str] = {
        r["boonz_product_id"]: r["pod_product_id"]
        for r in mapping_rows
        if r.get("pod_product_id") and r.get("boonz_product_id")
    }

    # pod_product_id → (name, category)
    ppid_info: dict[str, tuple[str, str | None]] = {
        r["pod_product_id"]: (r.get("pod_product_name") or "", r.get("product_category"))
        for r in pod_rows
    }

    # boonz_product_id → attr_drink
    bid_attr_drink: dict[str, bool] = {
        r["product_id"]: bool(r.get("attr_drink") or False)
        for r in boonz_rows
    }

    # pod_product_id → (score, signal)
    plg_map: dict[str, tuple[float, str]] = {
        r["pod_product_id"]: (
            float(r.get("score") or 0.0),
            (r.get("signal") or "KEEP").upper(),
        )
        for r in plg_rows
    }

    # ── Step 3: assemble candidate pool ──────────────────────────────────
    pool: dict[str, _WarehouseCandidate] = {}

    for bid in eligible_bids:
        ppid = bid_to_ppid.get(bid)
        if not ppid:
            continue  # Rule 5: must have a pod_product_id mapping

        name, category = ppid_info.get(ppid, ("", None))
        if not name:
            continue

        g_score, g_signal = plg_map.get(ppid, (0.0, "KEEP"))
        if g_signal == "ROTATE OUT":
            continue  # Rule 6: skip rotating-out products

        attr_drink = bid_attr_drink.get(bid, False)
        agg = wh_agg[bid]

        # If same pod_product_id already in pool (multiple boonz variants),
        # keep the one with most total stock
        if ppid in pool:
            existing_stock = pool[ppid]["total_stock"]
            new_stock = int(agg["total_stock"])
            if new_stock <= existing_stock:
                continue
            # Update stock but keep other fields
            pool[ppid] = _WarehouseCandidate(
                pod_product_id=ppid,
                pod_product_name=name,
                product_category=category,
                attr_drink=attr_drink,
                total_stock=new_stock,
                earliest_expiry=agg["earliest_expiry"],
                global_score=g_score,
                global_signal=g_signal,
            )
        else:
            pool[ppid] = _WarehouseCandidate(
                pod_product_id=ppid,
                pod_product_name=name,
                product_category=category,
                attr_drink=attr_drink,
                total_stock=int(agg["total_stock"]),
                earliest_expiry=agg["earliest_expiry"],
                global_score=g_score,
                global_signal=g_signal,
            )

    return pool


# ── Machine product index ────────────────────────────────────────────────────

def _build_machine_products(fleet: FleetState) -> dict[str, set[str]]:
    """Returns machine_id → set of pod_product_ids currently on that machine."""
    index: dict[str, set[str]] = {}
    for slot in fleet["slots"]:
        ppid = slot.get("pod_product_id")
        if ppid:
            index.setdefault(slot["machine_id"], set()).add(ppid)
    return index


# ── Current product category lookup ─────────────────────────────────────────

def _build_product_category_map(client: Client) -> dict[str, str | None]:
    """Returns pod_product_id → product_category."""
    resp = (
        client.table("pod_products")
        .select("pod_product_id, product_category")
        .limit(10000)
        .execute()
    )
    return {
        r["pod_product_id"]: r.get("product_category")
        for r in (resp.data or [])
    }


# ── Main entry point ─────────────────────────────────────────────────────────

def run_engine_c(
    fleet: FleetState,
    portfolio: PortfolioResult,
    refill_plan: RefillPlan,
) -> SwapPlan:
    """
    Score swap candidates for DISCONTINUE and swap-minimum slots.

    fleet:       from fetch_fleet_state()
    portfolio:   from run_engine_1()
    refill_plan: from run_engine_b()

    Returns SwapPlan. READ ONLY — no DB writes.
    """
    client = _get_client()

    # ── Startup fetches ────────────────────────────────────────────────────
    # candidates_pool and product_category_map can be fetched in parallel
    # but candidates_pool already does 5 parallel queries internally.
    # Fetch pod_products category map piggybacks on the same data already
    # fetched inside _fetch_candidates_pool; re-use client for simplicity.
    candidates_pool = _fetch_candidates_pool(client)
    product_category_map = _build_product_category_map(client)
    machine_products = _build_machine_products(fleet)

    # Machine venue_group lookup
    machine_venue: dict[str, str] = {
        mid: (meta.get("venue_group") or "INDEPENDENT").upper()
        for mid, meta in fleet["machines"].items()
    }

    # ── Identify eligible lines ────────────────────────────────────────────
    eligible_lines: list[SlotRefillLine] = [
        line for line in refill_plan["lines"]
        if line["final_action"] == "DISCONTINUE" or line["is_swap_minimum"]
    ]

    proposals: list[SlotSwapProposal] = []
    total_scored = 0

    for line in eligible_lines:
        machine_id = line["machine_id"]
        aisle_code = line["aisle_code"]
        current_ppid = line["pod_product_id"]
        goods_name = line["pod_product_name"]
        swap_trigger = (
            "DISCONTINUE" if line["final_action"] == "DISCONTINUE"
            else "SWAP_MINIMUM"
        )

        venue_group = machine_venue.get(machine_id, "INDEPENDENT")
        is_vox_machine = venue_group == "VOX"
        on_machine: set[str] = machine_products.get(machine_id, set())

        # Current product category (for category matching)
        current_category: str | None = (
            product_category_map.get(current_ppid) if current_ppid else None
        )

        # ── Filter and score candidates ────────────────────────────────────
        scored: list[SwapCandidate] = []

        for ppid, cand in candidates_pool.items():
            # Rule 4: not the same product being replaced
            if ppid == current_ppid:
                continue

            # Rule 2: not already on this machine
            if ppid in on_machine:
                continue

            # Rule 3: VOX restriction
            cand_name = cand["pod_product_name"]
            is_vox_product = any(
                vr.lower() == cand_name.lower() or vr.lower() in cand_name.lower()
                for vr in VOX_RESTRICTED
            )
            if is_vox_product and not is_vox_machine:
                continue

            # Rules 1, 5, 6 already enforced in _fetch_candidates_pool
            # (stock >= 3, has pod_product_id, global_signal != ROTATE OUT)

            # Category match
            cat_match = _same_category(current_category, cand["product_category"])

            # Score (slot_age_days_of_best_performer not used in v1 formula)
            conf_score = score_candidate(
                candidate_global_score=cand["global_score"],
                is_same_category=cat_match,
                warehouse_stock=cand["total_stock"],
                slot_age_days_of_best_performer=0,
            )
            conf_label = _confidence_label(conf_score)

            # Reason sentence
            cat_note = f" (same category: {cand['product_category']})" if cat_match else ""
            reason = (
                f"{cand['pod_product_name']} — global score {cand['global_score']:.1f} "
                f"({cand['global_signal']}){cat_note}, "
                f"{cand['total_stock']} units in warehouse."
            )

            scored.append(SwapCandidate(
                pod_product_id=ppid,
                pod_product_name=cand_name,
                global_score=cand["global_score"],
                global_signal=cand["global_signal"],
                warehouse_stock=cand["total_stock"],
                earliest_expiry=cand["earliest_expiry"],
                confidence_score=conf_score,
                confidence_label=conf_label,
                reason=reason,
                is_same_category=cat_match,
                attr_drink=cand["attr_drink"],
            ))

        total_scored += len(scored)

        # Sort descending by confidence_score, then by global_score as tiebreak
        scored.sort(key=lambda c: (c["confidence_score"], c["global_score"]), reverse=True)
        top3 = scored[:3]

        # No-candidate reason
        no_reason: str | None = None
        if not top3:
            if not candidates_pool:
                no_reason = "No warehouse stock meeting criteria"
            elif all(ppid in on_machine for ppid in candidates_pool if ppid != current_ppid):
                no_reason = "All eligible products already on this machine"
            elif not is_vox_machine and all(
                any(vr.lower() in c["pod_product_name"].lower() for vr in VOX_RESTRICTED)
                for ppid, c in candidates_pool.items()
                if ppid != current_ppid and ppid not in on_machine
            ):
                no_reason = "No warehouse stock meeting criteria for this venue_group"
            else:
                no_reason = "No eligible candidates after applying all filters"

        proposals.append(SlotSwapProposal(
            machine_id=machine_id,
            machine_name=line["machine_name"],
            aisle_code=aisle_code,
            slot_name=line["slot_name"],
            current_product=goods_name,
            current_pod_product_id=current_ppid,
            swap_trigger=swap_trigger,
            candidates=top3,
            top_candidate=top3[0] if top3 else None,
            no_candidate_reason=no_reason,
        ))

    slots_with = sum(1 for p in proposals if p["candidates"])
    slots_without = sum(1 for p in proposals if not p["candidates"])

    return SwapPlan(
        proposals=proposals,
        run_at=datetime.now(timezone.utc).isoformat(),
        eligible_slots=len(eligible_lines),
        slots_with_candidates=slots_with,
        slots_without_candidates=slots_without,
        total_candidates_scored=total_scored,
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
    refill_plan = run_engine_b(fleet, portfolio)
    print(f"  ✅  {refill_plan['slot_count']} lines, "
          f"{sum(1 for l in refill_plan['lines'] if l['refill_qty'] > 0)} to refill, "
          f"{refill_plan['skip_count']} skip")

    print("Running Engine C...")
    swap_plan = run_engine_c(fleet, portfolio, refill_plan)
    print(f"  ✅  {swap_plan['eligible_slots']} eligible slots processed")

    print()
    print(f"Swap Plan — {swap_plan['run_at']}")
    print(f"Eligible slots    : {swap_plan['eligible_slots']} (DISCONTINUE + swap_minimum)")
    print(f"With candidates   : {swap_plan['slots_with_candidates']}")
    print(f"Without candidates: {swap_plan['slots_without_candidates']}")
    print(f"Total scored      : {swap_plan['total_candidates_scored']}")

    print()
    print("Sample proposals (first 10):")
    for proposal in swap_plan["proposals"][:10]:
        trigger_label = proposal["swap_trigger"]
        print(
            f"\n[{proposal['machine_name'][:22]:<22}] "
            f"{proposal['aisle_code']:<7} "
            f"{proposal['current_product'][:25]:<25} "
            f"→ SWAP ({trigger_label})"
        )
        if proposal["candidates"]:
            for i, cand in enumerate(proposal["candidates"], 1):
                cat_flag = "✓" if cand["is_same_category"] else "✗"
                print(
                    f"  Candidate {i}: {cand['pod_product_name'][:30]:<30} "
                    f"score={cand['global_score']:.1f} "
                    f"conf={cand['confidence_score']:.3f} [{cand['confidence_label']}] "
                    f"wh={cand['warehouse_stock']} cat={cat_flag}"
                )
                print(f"    \"{cand['reason'][:90]}\"")
        else:
            print(f"  NO CANDIDATES — {proposal['no_candidate_reason']}")

    # Any beyond the first 10 that have no candidates
    no_cand_extra = [
        p for p in swap_plan["proposals"][10:]
        if not p["candidates"]
    ]
    if no_cand_extra:
        print(f"\n  … {len(no_cand_extra)} more slots without candidates (not shown)")

    print()
    print("✅  Engine C smoke test complete.")
