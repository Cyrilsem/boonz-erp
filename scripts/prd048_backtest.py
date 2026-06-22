#!/usr/bin/env python3
"""
PRD-048 ADD-brain base-stock backtest harness.

Monte-Carlo simulation comparing the LEGACY velocity-cover x band sizing against the
new BASE-STOCK (order-up-to S) sizing, on the 5 pilot machines, under two service regimes:

  Regime 1 - responsive picker : continuous review; a machine is visited the day ANY of its
             shelves hits zero. Top up to policy level. Metric of interest = TRIPS.
  Regime 2 - fixed route       : every machine visited on a fixed cadence (default weekly).
             Metric of interest = service % / lost units (the safety term must bridge the gap).

Demand is Poisson per shelf per day, lambda = real 28d sales rate (v30/30, falling back to
v7/7 when no 30d history). COMMON RANDOM NUMBERS: the same demand draw stream is reused for
both policies and both regimes within a replication, so differences are pure policy effect.

Pure stdlib (no numpy) so it runs anywhere. Inputs: scripts/prd048_pilot_shelves.json
(exported from prod via Supabase MCP; see PRD-048 EXECUTION-LOG for the export query).

Usage:  python3 scripts/prd048_backtest.py [--reps 500] [--horizon 28] [--route-days 7] [--seed 42]
"""
import json, math, os, sys, random, argparse
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "prd048_pilot_shelves.json")

# ---- policy params (mirror refill_policy_params defaults) ----
MIN_FILL_PCT = 0.70
SELLER_WK_THRESHOLD = 1.5
EWMA_W7, EWMA_W30 = 0.7, 0.3
SPOILAGE_FACTOR = 0.8
LEGACY_DAYS_COVER = 14   # engine_add_pod default p_days_cover


def rnd_half_up(x):
    """Postgres round() = half away from zero (x>=0 here)."""
    return int(math.floor(x + 0.5))


# ---------- sizing policies ----------
def base_stock_target(s):
    """Port of public.compute_base_stock_decision -> returns order-up-to target level."""
    v7, v30, cap = s["v7"], s["v30"], s["cap"]
    cold = bool(s["cold"]); slife = s["shelf_life"]; z = s["z"]; T = max(s["trip_days"], 1)
    no_vel = (v7 == 0 and v30 == 0)
    mu = EWMA_W7 * (v7 / 7.0) + EWMA_W30 * (v30 / 30.0)
    sigma = math.sqrt(max(mu, 0.0))
    is_seller = (mu * 7.0) >= SELLER_WK_THRESHOLD
    spoil = (mu * slife * SPOILAGE_FACTOR) if slife is not None else None
    s_raw = mu * T + z * sigma * math.sqrt(T)
    s_capped = min(s_raw, spoil) if spoil is not None else s_raw
    if no_vel and not cold:
        return 0
    if no_vel and cold:
        return min(cap, math.ceil(MIN_FILL_PCT * cap))
    floor = math.ceil(MIN_FILL_PCT * cap) if is_seller else 0
    if is_seller and spoil is not None:
        floor = min(floor, rnd_half_up(spoil))   # PRD-048 4.5: spoilage dominates floor
    return min(cap, max(rnd_half_up(s_capped), floor))


def legacy_add(s, band_fraction, oh):
    """Port of engine_add_pod v18 covered/flagged cover_units (the legacy add for one visit)."""
    v7, v30, cap = s["v7"], s["v30"], s["cap"]
    if v7 == 0 and v30 == 0:
        return 0  # DEAD -> no refill
    blend = 0.6 * v7 + 0.4 * v30
    cover = max(rnd_half_up(blend * LEGACY_DAYS_COVER * band_fraction), 1)
    return max(0, min(cover, cap - oh))


def base_stock_add(s, oh):
    target = base_stock_target(s)
    return max(0, min(target - oh, s["cap"] - oh))


# ---------- machine band assignment (legacy ranks shelves within a machine) ----------
def assign_bands(shelves):
    """ntile(3) by v30 desc within machine -> band_fraction per shelf index."""
    order = sorted(range(len(shelves)), key=lambda i: (-shelves[i]["v30"], -shelves[i]["v7"]))
    n = len(order); frac = {}
    for rank, i in enumerate(order):
        third = rank * 3 // n  # 0,1,2
        frac[i] = (1.00, 0.60, 0.30)[third]
    return frac


# ---------- Poisson draw (Knuth) ----------
def poisson(rng, lam):
    if lam <= 0:
        return 0
    L = math.exp(-lam); k = 0; p = 1.0
    while True:
        k += 1; p *= rng.random()
        if p <= L:
            return k - 1


# ---------- simulation ----------
def simulate(machines, policy, regime, horizon, route_days, demand_streams):
    """
    policy: 'legacy' | 'base_stock'
    regime: 'responsive' | 'fixed'
    demand_streams[(machine, shelf_code)] = list[int] length=horizon (common random numbers)
    Returns dict of metrics.
    """
    total_demand = 0; lost_units = 0; lost_aed = 0.0; trips = 0
    fill_accum = 0.0; fill_n = 0
    for m, shelves in machines.items():
        bands = assign_bands(shelves)
        stock = [s["oh"] for s in shelves]
        # "tracked" = shelves the policy intends to keep stocked. A dead shelf (target 0 /
        # no velocity) is intentionally left empty and MUST NOT trigger a responsive trip,
        # else every machine with a dead shelf gets visited daily (washes out the trip signal).
        if policy == "base_stock":
            tracked = [i for i, s in enumerate(shelves) if base_stock_target(s) > 0]
        else:
            tracked = [i for i, s in enumerate(shelves) if not (s["v7"] == 0 and s["v30"] == 0)]
        for day in range(horizon):
            # decide visit
            if regime == "fixed":
                visit = (day % route_days == 0)
            else:  # responsive: visit if any TRACKED shelf is stocked out at start of day
                visit = any(stock[i] <= 0 for i in tracked)
            if visit:
                trips += 1
                for i, s in enumerate(shelves):
                    if policy == "legacy":
                        add = legacy_add(s, bands[i], stock[i])
                    else:
                        add = base_stock_add(s, stock[i])
                    stock[i] += add
            # serve demand
            for i, s in enumerate(shelves):
                d = demand_streams[(m, s["shelf_code"])][day]
                total_demand += d
                served = min(d, stock[i])
                lost = d - served
                stock[i] -= served
                lost_units += lost
                lost_aed += lost * s["price"]
                fill_accum += stock[i] / s["cap"] if s["cap"] else 0
                fill_n += 1
    service = (1 - lost_units / total_demand) if total_demand else 1.0
    return {
        "service_pct": service * 100,
        "lost_units": lost_units,
        "lost_aed": lost_aed,
        "trips": trips,
        "avg_fill_pct": (fill_accum / fill_n * 100) if fill_n else 0,
        "total_demand": total_demand,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=500)
    ap.add_argument("--horizon", type=int, default=28)
    ap.add_argument("--route-days", type=int, default=7)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    with open(FIXTURE) as f:
        shelves = json.load(f)
    machines = defaultdict(list)
    for s in shelves:
        machines[s["machine"]].append(s)

    # ground-truth Poisson lambda per shelf = real sales rate (v30/30, fallback v7/7)
    lam = {}
    for s in shelves:
        l = s["v30"] / 30.0 if s["v30"] > 0 else (s["v7"] / 7.0 if s["v7"] > 0 else 0.0)
        lam[(s["machine"], s["shelf_code"])] = l

    regimes = ["responsive", "fixed"]
    policies = ["legacy", "base_stock"]
    agg = {(r, p): defaultdict(float) for r in regimes for p in policies}

    for rep in range(args.reps):
        # COMMON RANDOM NUMBERS: one demand stream per shelf per rep, shared by all policies/regimes
        streams = {}
        for key, l in lam.items():
            rng = random.Random((args.seed, rep, key[0], key[1]).__hash__())
            streams[key] = [poisson(rng, l) for _ in range(args.horizon)]
        for r in regimes:
            for p in policies:
                mres = simulate(machines, p, r, args.horizon, args.route_days, streams)
                for k, v in mres.items():
                    agg[(r, p)][k] += v

    # average
    for key in agg:
        for k in agg[key]:
            agg[key][k] /= args.reps

    # ---- report ----
    print(f"\nPRD-048 BACKTEST  | reps={args.reps} horizon={args.horizon}d route={args.route_days}d "
          f"seed={args.seed} | 5 pilot machines, {len(shelves)} shelves\n")
    hdr = f"{'regime':<12}{'policy':<12}{'service%':>9}{'lost_u':>9}{'lost_AED':>10}{'trips':>8}{'avg_fill%':>10}"
    print(hdr); print("-" * len(hdr))
    for r in regimes:
        for p in policies:
            a = agg[(r, p)]
            print(f"{r:<12}{p:<12}{a['service_pct']:>9.2f}{a['lost_units']:>9.2f}"
                  f"{a['lost_aed']:>10.2f}{a['trips']:>8.2f}{a['avg_fill_pct']:>10.2f}")
        print()

    # ---- acceptance checks (PRD-048 7) ----
    print("ACCEPTANCE (PRD-048 7):")
    rr = agg[("responsive", "base_stock")]; rl = agg[("responsive", "legacy")]
    fb = agg[("fixed", "base_stock")]; fl = agg[("fixed", "legacy")]
    c1 = rr["trips"] <= rl["trips"] + 1e-9 and rr["service_pct"] >= rl["service_pct"] - 0.5
    c2 = fb["lost_units"] <= fl["lost_units"] + 1e-9
    print(f"  responsive: base_stock trips <= legacy at >= service ........ {'PASS' if c1 else 'REVIEW'}"
          f"  ({rr['trips']:.1f} vs {rl['trips']:.1f} trips; {rr['service_pct']:.2f}% vs {rl['service_pct']:.2f}%)")
    print(f"  fixed route: base_stock lost_units < legacy ................. {'PASS' if c2 else 'REVIEW'}"
          f"  ({fb['lost_units']:.2f} vs {fl['lost_units']:.2f} lost units)")
    print("  no floor-on-tail: gated on is_seller in compute_base_stock_decision (unit-tested, PRD-048 4.1)\n")


if __name__ == "__main__":
    main()
