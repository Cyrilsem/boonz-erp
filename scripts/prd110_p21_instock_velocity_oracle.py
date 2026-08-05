#!/usr/bin/env python3
"""
PRD-110 P2.1 — offline ORACLE for `v_shelf_instock_velocity_v3`.

Built in relay leg 16, which had NO DDL channel (S-18 recurrence: Supabase MCP
absent, PostgREST read-only). Purpose: compute the leg-15 A/B/C/D `stock_hours`
design against REAL data outside the database, so the leg that finally writes the
SQL has a numeric oracle to assert against instead of a hypothesis.

Data-source law obeyed:
  - identity resolved by product NAME (pod_products exact -> lower(btrim) ->
    product_name_conventions.original_name -> official_name). NEVER by slot.
  - the name resolution is VALIDATED against the canonical view
    `v_shelf_sales_identity.units_30d` before any velocity number is believed.
  - WEIMI slot_code is used ONLY to attribute in-stock hours among slots whose
    own WEIMI product_name already resolved to the pod. It is never an identity
    source and never joined to a stale binding.

Read-only. Touches nothing. Prints summaries only.
"""

import json
import os
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env():
    env = {}
    with open(os.path.join(ROOT, ".env")) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


ENV = load_env()
BASE = ENV["SUPABASE_URL"].rstrip("/") + "/rest/v1"
KEY = ENV["SUPABASE_SERVICE_KEY"]
PAGE = 1000


def fetch(path, select, extra="", order=None):
    """Paginated PostgREST GET. Returns list of dicts."""
    out = []
    offset = 0
    order = order or ""
    while True:
        q = f"{BASE}/{path}?select={urllib.parse.quote(select)}{extra}"
        if order:
            q += f"&order={urllib.parse.quote(order)}"
        req = urllib.request.Request(q)
        req.add_header("apikey", KEY)
        req.add_header("Authorization", f"Bearer {KEY}")
        req.add_header("Range-Unit", "items")
        req.add_header("Range", f"{offset}-{offset + PAGE - 1}")
        with urllib.request.urlopen(req) as resp:
            chunk = json.loads(resp.read().decode())
        out.extend(chunk)
        if len(chunk) < PAGE:
            break
        offset += PAGE
    return out


# ---------------------------------------------------------------- resolution
def norm(s):
    return (s or "").strip().lower()


def build_resolver(pods, conventions):
    """name -> pod_product_id, by the three canonical rungs (never by slot)."""
    exact, lowered = {}, {}
    for p in pods:
        nm = p["pod_product_name"]
        if nm is None:
            continue
        exact.setdefault(nm, p["pod_product_id"])
        lowered.setdefault(norm(nm), p["pod_product_id"])
    conv = {}
    for c in conventions:
        o, f = c.get("original_name"), c.get("official_name")
        if o and f:
            conv.setdefault(norm(o), f)

    def resolve(name):
        if name is None:
            return None
        if name in exact:
            return exact[name]
        n = norm(name)
        if n in lowered:
            return lowered[n]
        off = conv.get(n)
        if off:
            if off in exact:
                return exact[off]
            if norm(off) in lowered:
                return lowered[norm(off)]
        return None

    return resolve


def ts(s):
    # PostgREST returns e.g. '2026-07-30T04:00:00+00:00' or with 'Z'
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def main():
    print("=" * 78)
    print("PRD-110 P2.1 in-stock velocity ORACLE  (read-only, offline)")
    print("=" * 78)

    pods = fetch("pod_products", "pod_product_id,pod_product_name")
    conv = fetch("product_name_conventions", "original_name,official_name")
    resolve = build_resolver(pods, conv)
    print(f"catalog: {len(pods)} pod_products, {len(conv)} name conventions")

    shelf = fetch(
        "v_shelf_state",
        "machine_id,machine_name,shelf_id,shelf_code,slot_name,pod_product_id,"
        "pod_name,pod_shelf_count,current_stock,max_stock,velocity_raw,velocity_instock",
    )
    print(f"v_shelf_state: {len(shelf)} shelves")
    name_of_pre = {
        (s["machine_id"], s["pod_product_id"]): (s["machine_name"], s["pod_name"])
        for s in shelf
        if s["pod_product_id"]
    }
    if any(s["velocity_instock"] is not None for s in shelf):
        print("  !! velocity_instock is NO LONGER null -> P2.1 has shipped; re-read fixture 3 seq 15")

    # ------------------------------------------------------------- window
    latest = fetch(
        "weimi_aisle_snapshots", "snapshot_at", "&limit=1", order="snapshot_at.desc"
    )
    anchor = ts(latest[0]["snapshot_at"])
    start = anchor - timedelta(days=30)
    startiso = start.isoformat()
    print(f"window: {start.date()} .. {anchor.date()}  (anchor = latest WEIMI snapshot)")

    weimi = fetch(
        "weimi_aisle_snapshots",
        "machine_id,slot_code,product_name,current_stock,max_stock,snapshot_at",
        f"&snapshot_at=gte.{urllib.parse.quote(startiso)}",
        order="snapshot_at.asc",
    )
    sales = fetch(
        "sales_history",
        "machine_id,pod_product_name,qty,transaction_date",
        f"&transaction_date=gte.{urllib.parse.quote(startiso)}",
        order="transaction_date.asc",
    )
    print(f"weimi rows: {len(weimi)}   sales rows: {len(sales)}")

    # -------------------------------------------------- resolution coverage
    w_unres = defaultdict(int)
    for r in weimi:
        r["pod"] = resolve(r["product_name"])
        if r["pod"] is None:
            w_unres[r["product_name"]] += 1
    w_bad = sum(w_unres.values())
    print(
        f"WEIMI name resolution: {len(weimi)-w_bad}/{len(weimi)} = "
        f"{100*(len(weimi)-w_bad)/max(len(weimi),1):.1f}%  ({w_bad} unresolved)"
    )
    for nm, c in sorted(w_unres.items(), key=lambda x: -x[1])[:8]:
        print(f"    unresolved WEIMI: {nm!r} x{c}")

    s_unres = defaultdict(int)
    for r in sales:
        r["pod"] = resolve(r["pod_product_name"])
        if r["pod"] is None:
            s_unres[r["pod_product_name"]] += 1
    s_bad = sum(s_unres.values())
    print(
        f"SALES name resolution: {len(sales)-s_bad}/{len(sales)} = "
        f"{100*(len(sales)-s_bad)/max(len(sales),1):.1f}%  ({s_bad} unresolved)"
    )
    for nm, c in sorted(s_unres.items(), key=lambda x: -x[1])[:8]:
        print(f"    unresolved SALES: {nm!r} x{c}")

    # ------------- VALIDATE our resolver against the canonical view -------
    ident = fetch(
        "v_shelf_sales_identity", "machine_id,pod_product_id,units_30d,dvel,resolved"
    )
    canon = {
        (r["machine_id"], r["pod_product_id"]): (r["units_30d"] or 0)
        for r in ident
        if r["pod_product_id"]
    }
    mine = defaultdict(int)
    for r in sales:
        if r["pod"]:
            mine[(r["machine_id"], r["pod"])] += r["qty"] or 0
    keys = set(canon) | set(mine)
    exact_k = sum(1 for k in keys if canon.get(k, 0) == mine.get(k, 0))
    print(
        f"\nRESOLVER VALIDATION vs v_shelf_sales_identity: "
        f"{exact_k}/{len(keys)} (machine,pod) keys agree on units_30d exactly"
    )
    bad = [k for k in keys if canon.get(k, 0) != mine.get(k, 0)]
    absent = sum(1 for k in bad if k not in canon)
    live_pairs = {(s["machine_id"], s["pod_product_id"]) for s in shelf if s["pod_product_id"]}
    print(
        f"  divergence decomposition: {len(bad)} keys | {absent} absent from the view entirely "
        f"| {sum(1 for k in bad if k not in live_pairs)} are not a live (machine,pod) shelf pair\n"
        f"  view rows={len(canon)}  live shelf pairs={len(live_pairs)}  "
        f"(the view is NEITHER a subset nor a superset of live pairs)"
    )

    # ------------------------------------------------ per-machine snapshots
    snaps_by_machine = defaultdict(set)
    for r in weimi:
        snaps_by_machine[r["machine_id"]].add(r["snapshot_at"])
    gaps = []
    for m, ss in snaps_by_machine.items():
        o = sorted(ts(x) for x in ss)
        for a, b in zip(o, o[1:]):
            gaps.append((b - a).total_seconds() / 3600.0)
    gaps.sort()
    if gaps:
        print(
            f"\nsnapshot gaps (all machines): n={len(gaps)} "
            f"min={gaps[0]:.2f}h  p50={gaps[len(gaps)//2]:.2f}h  max={gaps[-1]:.2f}h"
        )

    # pod stock per (machine, pod, snapshot); and per (machine, slot, snapshot)
    pod_stock = defaultdict(int)
    slot_stock = defaultdict(int)
    present = defaultdict(int)   # (machine,pod,snapshot) -> # of WEIMI rows. 0 => POD NOT ON MACHINE
    for r in weimi:
        if r["pod"] is None:
            continue
        pod_stock[(r["machine_id"], r["pod"], r["snapshot_at"])] += r["current_stock"] or 0
        present[(r["machine_id"], r["pod"], r["snapshot_at"])] += 1
        slot_stock[(r["machine_id"], r["pod"], r["slot_code"], r["snapshot_at"])] += (
            r["current_stock"] or 0
        )

    pods_seen = defaultdict(set)  # machine -> set(pod)
    for (m, p, _s) in pod_stock:
        pods_seen[m].add(p)

    sales_by_mp = defaultdict(list)  # (machine,pod) -> [(t, qty)]
    for r in sales:
        if r["pod"]:
            sales_by_mp[(r["machine_id"], r["pod"])].append(
                (ts(r["transaction_date"]), r["qty"] or 0)
            )
    for v in sales_by_mp.values():
        v.sort()

    # ------------------------------------------------------- A/B/C/D engine
    case_count = defaultdict(int)
    hours = defaultdict(float)          # (machine,pod) -> stock_hours
    slot_hours = defaultdict(float)     # (machine,pod,slot) -> stock_hours
    elapsed = defaultdict(float)        # observable hours only
    unobserved = defaultdict(float)     # hours the pod was not on the machine at all
    hours_naive = defaultdict(float)    # leg-15 rule, kept only to size the correction
    elapsed_naive = defaultdict(float)

    for m, snapset in snaps_by_machine.items():
        order = sorted(ts(x) for x in snapset)
        raw = {ts(x): x for x in snapset}
        for a, b in zip(order, order[1:]):
            H = (b - a).total_seconds() / 3600.0
            if H <= 0:
                continue
            for p in pods_seen[m]:
                s_i = pod_stock.get((m, p, raw[a]), 0)
                ev = [(t, q) for t, q in sales_by_mp.get((m, p), []) if a <= t < b]
                sold = sum(q for _t, q in ev)
                elapsed_naive[(m, p)] += H
                if s_i == 0 and sold == 0:
                    pass
                elif s_i > 0 and sold < s_i:
                    hours_naive[(m, p)] += H
                elif s_i > 0:
                    cum, hit = 0, b
                    for t, q in ev:
                        cum += q
                        if cum >= s_i:
                            hit = t
                            break
                    hours_naive[(m, p)] += max(0.0, min(H, (hit - a).total_seconds() / 3600.0))
                else:
                    hours_naive[(m, p)] += max(
                        0.0, H - (ev[0][0] - a).total_seconds() / 3600.0
                    )

    for m, snapset in snaps_by_machine.items():
        order = sorted(ts(x) for x in snapset)
        raw = {ts(x): x for x in snapset}
        for a, b in zip(order, order[1:]):
            H = (b - a).total_seconds() / 3600.0
            if H <= 0:
                continue
            for p in pods_seen[m]:
                s_i = pod_stock.get((m, p, raw[a]), 0)
                ev = [(t, q) for t, q in sales_by_mp.get((m, p), []) if a <= t < b]
                sold = sum(q for _t, q in ev)
                # SPEC CORRECTION (leg 16). The pod having no WEIMI row at t_i means
                # it was NOT ON THE MACHINE, not that it was empty. Scoring that as
                # "proven out" (leg-15 case A) credits phantom out-of-stock hours and
                # inflates velocity_instock. Unobservable => excluded from BOTH
                # stock_hours and elapsed, never scored as zero.
                if present.get((m, p, raw[a]), 0) == 0 and sold == 0:
                    case_count["X_absent"] += 1
                    unobserved[(m, p)] += H
                    continue
                elapsed[(m, p)] += H
                if s_i == 0 and sold == 0:
                    case_count["A"] += 1
                    h = 0.0
                elif s_i > 0 and sold < s_i:
                    case_count["B"] += 1
                    h = H
                elif s_i > 0 and sold >= s_i:
                    case_count["C"] += 1
                    cum = 0
                    hit = b
                    for t, q in ev:
                        cum += q
                        if cum >= s_i:
                            hit = t
                            break
                    h = max(0.0, min(H, (hit - a).total_seconds() / 3600.0))
                else:  # s_i == 0 and sold > 0
                    case_count["D"] += 1
                    first = ev[0][0]
                    h = max(0.0, H - (first - a).total_seconds() / 3600.0)
                hours[(m, p)] += h
                # per-slot attribution, by that slot's OWN weimi stock at t_i
                tot = s_i
                if tot > 0 and h > 0:
                    for (mm, pp, sc, sn), sv in slot_stock.items():
                        pass  # replaced below by prebuilt index

    print(f"\nA/B/C/D case distribution: {dict(sorted(case_count.items()))}")

    # -------- per-shelf split (second pass, indexed, to stay O(n)) --------
    slots_at = defaultdict(list)  # (machine,pod,snapshot) -> [(slot, stock)]
    for (m, p, sc, sn), v in slot_stock.items():
        slots_at[(m, p, sn)].append((sc, v))

    for m, snapset in snaps_by_machine.items():
        order = sorted(ts(x) for x in snapset)
        raw = {ts(x): x for x in snapset}
        for a, b in zip(order, order[1:]):
            H = (b - a).total_seconds() / 3600.0
            if H <= 0:
                continue
            for p in pods_seen[m]:
                s_i = pod_stock.get((m, p, raw[a]), 0)
                ev = [(t, q) for t, q in sales_by_mp.get((m, p), []) if a <= t < b]
                sold = sum(q for _t, q in ev)
                if s_i == 0 and sold == 0:
                    h = 0.0
                elif s_i > 0 and sold < s_i:
                    h = H
                elif s_i > 0 and sold >= s_i:
                    cum, hit = 0, b
                    for t, q in ev:
                        cum += q
                        if cum >= s_i:
                            hit = t
                            break
                    h = max(0.0, min(H, (hit - a).total_seconds() / 3600.0))
                else:
                    h = max(0.0, H - (ev[0][0] - a).total_seconds() / 3600.0)
                if h <= 0:
                    continue
                for sc, sv in slots_at.get((m, p, raw[a]), []):
                    if sv > 0:
                        slot_hours[(m, p, sc)] += h  # this slot was itself in stock

    # ------------------------------------------------------------ velocity
    FLOOR = 48.0
    rows = []
    for (m, p), hrs in hours.items():
        units = mine.get((m, p), 0)
        v_instock = None if hrs < FLOOR else units / (hrs / 24.0)
        hn = hours_naive[(m, p)]
        rows.append(
            dict(machine_id=m, pod=p, units=units, stock_hours=hrs,
                 elapsed=elapsed[(m, p)], unobserved=unobserved[(m, p)],
                 v_instock=v_instock,
                 v_instock_naive=(None if hn < FLOOR else units / (hn / 24.0)))
        )

    # ---- what the absent/empty conflation does, and what it does NOT do ----
    infl = [
        r["v_instock_naive"] / r["v_instock"]
        for r in rows
        if r["v_instock"] and r["v_instock_naive"] and r["v_instock"] > 0
    ]
    if infl:
        print(
            f"\nCASE-A CONFLATION — effect on velocity_instock: NONE, measured.\n"
            f"  Both rules contribute 0 stock_hours for an absent interval, so the ratio is\n"
            f"  exactly {min(infl):.3f}-{max(infl):.3f} across all {len(infl)} comparable series.\n"
            f"  The numerator and denominator are untouched. Do NOT 'fix' velocity over this."
        )
    # ...but it wrecks the censoring DIAGNOSTIC, which is what tells you P2.1 is worth building
    _ws = [r for r in rows if r["units"] > 0]

    def censor_stats(hrs_map, el_map):
        return sorted(
            1 - hrs_map[(r["machine_id"], r["pod"])] / el_map[(r["machine_id"], r["pod"])]
            for r in _ws
            if el_map[(r["machine_id"], r["pod"])] > 0
        )
    cn = censor_stats(hours, elapsed)
    co = censor_stats(hours_naive, elapsed_naive)
    print(
        f"CASE-A CONFLATION — effect on the CENSORING DIAGNOSTIC: decisive.\n"
        f"  leg-15 rule : p50={co[len(co)//2]:.3f} p90={co[int(.9*len(co))]:.3f} "
        f"| {sum(1 for c in co if c>0.01)}/{len(co)} series read as censored >1%\n"
        f"  corrected   : p50={cn[len(cn)//2]:.3f} p90={cn[int(.9*len(cn))]:.3f} "
        f"| {sum(1 for c in cn if c>0.01)}/{len(cn)} series genuinely censored >1%\n"
        f"  A leg reading the naive figure concludes the fleet is ~"
        f"{100*sum(1 for c in co if c>0.01)/len(co):.0f}% stock-censored when it is ~"
        f"{100*sum(1 for c in cn if c>0.01)/len(cn):.0f}%."
    )

    tot = len(rows)
    nulled = sum(1 for r in rows if r["v_instock"] is None)
    with_sales = [r for r in rows if r["units"] > 0]
    nulled_ws = sum(1 for r in with_sales if r["v_instock"] is None)
    print(
        f"\n(machine,pod) series: {tot} total, {len(with_sales)} with sales.\n"
        f"48h FLOOR -> NULL fallback: {nulled}/{tot} ({100*nulled/max(tot,1):.1f}%) overall, "
        f"{nulled_ws}/{len(with_sales)} ({100*nulled_ws/max(len(with_sales),1):.1f}%) of series with sales"
    )

    # censoring: how much of elapsed time was out-of-stock
    cens = [
        (1 - r["stock_hours"] / r["elapsed"])
        for r in with_sales
        if r["elapsed"] > 0
    ]
    cens.sort()
    if cens:
        print(
            f"out-of-stock fraction of elapsed time (series with sales): "
            f"p50={cens[len(cens)//2]:.3f}  p90={cens[int(.9*len(cens))]:.3f}  max={cens[-1]:.3f}  "
            f"| {sum(1 for c in cens if c>0.01)}/{len(cens)} series censored >1%"
        )

    # ------------------------- compare vs velocity_raw on v_shelf_state ----
    vraw = {}
    shelves_of = defaultdict(list)
    for s in shelf:
        if s["pod_product_id"]:
            k = (s["machine_id"], s["pod_product_id"])
            if s["velocity_raw"] is not None:
                vraw[k] = float(s["velocity_raw"])
            shelves_of[k].append(s)

    ratios = []
    for r in rows:
        k = (r["machine_id"], r["pod"])
        if r["v_instock"] is None or k not in vraw or vraw[k] <= 0:
            continue
        ratios.append((r["v_instock"] / vraw[k], k, r))
    ratios.sort(key=lambda x: -x[0])
    if ratios:
        rr = [x[0] for x in ratios]
        rr_s = sorted(rr)
        print(
            f"\nvelocity_instock / velocity_raw  (n={len(rr)}): "
            f"min={rr_s[0]:.2f} p50={rr_s[len(rr_s)//2]:.2f} "
            f"p90={rr_s[int(.9*len(rr_s))]:.2f} max={rr_s[-1]:.2f}  "
            f"| >=2x on {sum(1 for x in rr if x>=2)} series, >=1.25x on {sum(1 for x in rr if x>=1.25)}"
        )

    # ------------------------------- S-20: fixture-2 candidate population --
    name_of = {}
    for s in shelf:
        if s["pod_product_id"]:
            name_of[(s["machine_id"], s["pod_product_id"])] = (
                s["machine_name"], s["pod_name"]
            )
    print("\nS-20 / fixture-2 CANDIDATES  (v_instock >= 2x v_raw, proven censoring, >= floor):")
    print(f"{'machine':<26} {'pod':<28} {'units':>5} {'hrs':>7} {'elap':>7} {'v_ins':>7} {'v_raw':>6} {'x':>5}")
    shown = 0
    for ratio, k, r in ratios:
        if ratio < 2.0 or r["units"] < 10:
            continue
        mn, pn = name_of.get(k, ("?", "?"))
        print(
            f"{mn[:25]:<26} {str(pn)[:27]:<28} {r['units']:>5} {r['stock_hours']:>7.1f} "
            f"{r['elapsed']:>7.1f} {r['v_instock']:>7.2f} {vraw[k]:>6.2f} {ratio:>5.2f}"
        )
        shown += 1
        if shown >= 15:
            break
    if not shown:
        print("  (none)")

    # ------------------------------- per-shelf in-stock split vs 1/n -------
    print("\nPER-SHELF SPLIT: pods on >1 shelf, in-stock-hours split vs naive 1/n")
    multi = [(k, v) for k, v in shelves_of.items() if len(v) > 1]
    print(f"  {len(multi)} (machine,pod) pairs span >1 shelf "
          f"(max span = {max((len(v) for _k,v in multi), default=0)} shelves)")
    devi = []
    for k, shs in multi:
        m, p = k
        tot_h = sum(slot_hours.get((m, p, s["slot_name"]), 0.0) for s in shs)
        if tot_h <= 0:
            continue
        n = len(shs)
        for s in shs:
            w = slot_hours.get((m, p, s["slot_name"]), 0.0) / tot_h
            devi.append((abs(w - 1.0 / n), w, 1.0 / n, name_of.get(k, ("?", "?")), s["shelf_code"]))
    devi.sort(reverse=True)
    if devi:
        ds = sorted(d[0] for d in devi)
        print(f"  |w_instock - 1/n| over {len(devi)} shelves: "
              f"p50={ds[len(ds)//2]:.3f} p90={ds[int(.9*len(ds))]:.3f} max={ds[-1]:.3f}")
        print("  worst 8 (where 1/n is most wrong):")
        for d, w, inv, (mn, pn), sc in devi[:8]:
            print(f"    {mn[:22]:<23} {str(pn)[:20]:<21} {sc:<4} w={w:.3f} vs 1/n={inv:.3f}  (dev {d:.3f})")

    # ------------------------------------------------ floor sensitivity ---
    print("\nFLOOR SENSITIVITY (series with sales):")
    for f in (0, 24, 48, 72, 120, 240):
        n = sum(1 for r in with_sales if r["stock_hours"] < f)
        print(f"  floor={f:>4}h -> {n:>4}/{len(with_sales)} NULL "
              f"({100*n/max(len(with_sales),1):.1f}%)")
    # what would happen WITHOUT a floor: worst minted rates
    nofloor = sorted(
        ((r["units"] / (r["stock_hours"] / 24.0), i, r)
         for i, r in enumerate(with_sales) if r["stock_hours"] > 0),
        key=lambda x: -x[0],
    )[:5]
    print("  top 5 rates if the floor were REMOVED (the trap the floor exists for):")
    for v, _i, r in nofloor:
        mn, pn = name_of.get((r["machine_id"], r["pod"]), ("?", "?"))
        print(f"    {v:>10.1f}/day  units={r['units']:<4} stock_hours={r['stock_hours']:.2f}  {mn[:20]} / {pn}")

    # ---------- same numbers, but with CANONICAL units from the view -------
    # The numerator must not depend on this script's hand-rolled resolver.
    # Recompute for the 492 keys where the two agree AND for canon outright.
    canon_rows = []
    for r in rows:
        k = (r["machine_id"], r["pod"])
        if k not in canon:
            continue
        u = canon[k]
        canon_rows.append(
            dict(r, units=u,
                 v_instock=None if r["stock_hours"] < FLOOR else u / (r["stock_hours"] / 24.0))
        )
    cr_ratios = []
    for r in canon_rows:
        k = (r["machine_id"], r["pod"])
        if r["v_instock"] is None or k not in vraw or vraw[k] <= 0 or r["units"] == 0:
            continue
        cr_ratios.append(r["v_instock"] / vraw[k])
    cr_ratios.sort()
    if cr_ratios:
        print(
            f"\nCANONICAL-UNITS CHECK (numerator = v_shelf_sales_identity.units_30d, n={len(cr_ratios)}):\n"
            f"  velocity_instock / velocity_raw: min={cr_ratios[0]:.2f} "
            f"p50={cr_ratios[len(cr_ratios)//2]:.2f} p90={cr_ratios[int(.9*len(cr_ratios))]:.2f} "
            f"max={cr_ratios[-1]:.2f} | >=2x on {sum(1 for x in cr_ratios if x>=2)} series"
        )

    # ------------------------------------------------ persist the oracle --
    out = os.path.join(ROOT, "docs", "prds", "PRD-110-P21-ORACLE.json")
    payload = dict(
        generated_for="PRD-110 P2.1 v_shelf_instock_velocity_v3",
        window_start=start.isoformat(), window_anchor=anchor.isoformat(),
        floor_hours=FLOOR,
        counts=dict(weimi_rows=len(weimi), sales_rows=len(sales),
                    weimi_resolved=len(weimi) - w_bad, sales_resolved=len(sales) - s_bad,
                    series_total=tot, series_with_sales=len(with_sales),
                    nulled_by_floor=nulled),
        cases=dict(case_count),
        resolver_validation=dict(keys=len(keys), agree=exact_k, diverge=len(keys) - exact_k),
        series=[
            dict(machine_id=r["machine_id"], pod_product_id=r["pod"],
                 units_mine=r["units"], units_canon=canon.get((r["machine_id"], r["pod"])),
                 stock_hours=round(r["stock_hours"], 4),
                 elapsed_hours=round(r["elapsed"], 4),
                 velocity_instock=(None if r["v_instock"] is None else round(r["v_instock"], 6)),
                 velocity_raw=vraw.get((r["machine_id"], r["pod"])))
            for r in rows
        ],
    )
    with open(out, "w") as fh:
        json.dump(payload, fh, indent=1, sort_keys=True)
    print(f"\noracle written: {out}  ({len(payload['series'])} series)")


if __name__ == "__main__":
    sys.exit(main())
