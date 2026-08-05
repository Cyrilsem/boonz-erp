#!/usr/bin/env python3
"""PRD-110 S-23. Compare the applied v_shelf_instock_velocity_v3 against the leg-16 oracle.

The pointer's instruction is explicit: compare stock_hours FIRST (it is numerator-independent
and is the heart of the A/B/C/D mechanism), expect divergence, and ATTRIBUTE it rather than
"fix" it.

Two known, structural reasons the two objects cannot be identical:
  * source     - the oracle was computed on weimi_aisle_snapshots with a hand-rolled 3-rung
                 name resolver; the view reads weimi_device_status with 4 tiers (S-21).
  * window     - the oracle anchored at 2026-07-30T14:00:31Z; the view anchors at
                 max(weimi_device_status.snapshot_at), which moves as WEIMI ingests.

So the headline comparison is the WINDOW-NORMALISED in-stock fraction (stock_hours/elapsed_hours),
not raw stock_hours. Raw stock_hours is reported too, but read it knowing the windows differ.

Read-only. Touches nothing. PostgREST + service key, same channel as the leg-16 oracle.
"""

import json
import os
import statistics as st
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ORACLE = os.path.join(ROOT, "docs", "prds", "PRD-110-P21-ORACLE.json")


def load_env():
    env = {}
    with open(os.path.join(ROOT, ".env")) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v.strip().strip('"').strip("'")
    return env


ENV = load_env()
BASE = ENV["SUPABASE_URL"].rstrip("/") + "/rest/v1"
KEY = ENV["SUPABASE_SERVICE_KEY"]


def fetch(path, select, extra=""):
    """Paged PostgREST read."""
    out, step, off = [], 1000, 0
    while True:
        url = f"{BASE}/{path}?select={urllib.parse.quote(select)}{extra}&limit={step}&offset={off}"
        req = urllib.request.Request(
            url, headers={"apikey": KEY, "Authorization": "Bearer " + KEY}
        )
        with urllib.request.urlopen(req, timeout=600) as r:
            chunk = json.loads(r.read().decode())
        out.extend(chunk)
        if len(chunk) < step:
            return out
        off += step


def fetch_view_by_machine(select):
    """The view is too slow for PostgREST's 8s statement timeout fleet-wide, but the
    machine_id predicate pushes down, so one call per machine stays well under it.
    Falls back loudly rather than silently returning a short list."""
    machines = fetch("machines", "machine_id")
    rows, failed = [], []
    for i, m in enumerate(machines, 1):
        url = (
            f"{BASE}/v_shelf_instock_velocity_v3?select={urllib.parse.quote(select)}"
            f"&machine_id=eq.{m['machine_id']}"
        )
        req = urllib.request.Request(
            url, headers={"apikey": KEY, "Authorization": "Bearer " + KEY}
        )
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                rows.extend(json.loads(r.read().decode()))
        except Exception as exc:  # noqa: BLE001
            failed.append((m["machine_id"], str(exc)))
        if i % 10 == 0:
            print(f"    ...{i}/{len(machines)} machines, {len(rows)} series", flush=True)
    if failed:
        print(f"  !! {len(failed)} machine(s) FAILED - results are incomplete:")
        for mid, err in failed[:5]:
            print(f"     {mid} {err}")
    return rows


def f(x):
    return None if x is None else float(x)


def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    i = min(len(s) - 1, max(0, int(round((p / 100.0) * (len(s) - 1)))))
    return s[i]


def describe(name, vals, unit=""):
    if not vals:
        print(f"  {name:<26} (empty)")
        return
    print(
        f"  {name:<26} n={len(vals):<5} p10={pct(vals,10):.4f} p50={pct(vals,50):.4f} "
        f"p90={pct(vals,90):.4f} min={min(vals):.4f} max={max(vals):.4f}{unit}"
    )


def main():
    oracle = json.load(open(ORACLE))
    o_series = {
        (s["machine_id"], s["pod_product_id"]): s for s in oracle["series"]
    }

    print("  fetching the view one machine at a time (PostgREST 8s cap)...", flush=True)
    view = fetch_view_by_machine(
        "machine_id,pod_product_id,stock_hours,elapsed_hours,stock_censoring,"
        "units_30d_canonical,units_window,velocity_instock,velocity_raw,velocity_status,"
        "n_case_a,n_case_b,n_case_c,n_case_d,n_case_x,t_start,t_anchor,floor_hours"
    )
    v_series = {(r["machine_id"], r["pod_product_id"]): r for r in view}

    print("=" * 78)
    print("S-23 :: v_shelf_instock_velocity_v3  vs  PRD-110-P21-ORACLE.json")
    print("=" * 78)

    t_start = view[0]["t_start"] if view else "?"
    t_anchor = view[0]["t_anchor"] if view else "?"
    print("\n[0] WINDOWS - the first thing that must be established")
    print(f"  oracle : {oracle['window_start']}  ->  {oracle['window_anchor']}")
    print(f"  view   : {t_start}  ->  {t_anchor}")
    print(f"  oracle floor_hours={oracle['floor_hours']}  view floor_hours={view[0]['floor_hours']}")

    ok, vo, ov = (
        set(v_series) & set(o_series),
        set(v_series) - set(o_series),
        set(o_series) - set(v_series),
    )
    print("\n[1] KEY OVERLAP  (machine_id, pod_product_id)")
    print(f"  view series      {len(v_series)}")
    print(f"  oracle series    {len(o_series)}")
    print(f"  in BOTH          {len(ok)}")
    print(f"  view-only        {len(vo)}")
    print(f"  oracle-only      {len(ov)}")

    # ---------------------------------------------------------------- stock_hours, FIRST
    print("\n[2] stock_hours - raw (windows differ, so read [3] as the real test)")
    d_abs, ratio, pairs = [], [], []
    for k in ok:
        vs, os_ = f(v_series[k]["stock_hours"]), f(o_series[k]["stock_hours"])
        if vs is None or os_ is None:
            continue
        d_abs.append(vs - os_)
        pairs.append((k, vs, os_))
        if os_ > 0:
            ratio.append(vs / os_)
    describe("delta (view-oracle) h", d_abs)
    describe("ratio view/oracle", ratio)
    within = sum(1 for r in ratio if 0.95 <= r <= 1.05)
    print(f"  within +/-5%               {within}/{len(ratio)} = {100.0*within/max(1,len(ratio)):.1f}%")
    within20 = sum(1 for r in ratio if 0.80 <= r <= 1.20)
    print(f"  within +/-20%              {within20}/{len(ratio)} = {100.0*within20/max(1,len(ratio)):.1f}%")

    # ---------------------------------------------------------- window-normalised fraction
    print("\n[3] IN-STOCK FRACTION  stock_hours/elapsed_hours  - window-length-normalised")
    print("     This is the numerator-independent mechanism test.")
    fr_d, fr_pairs = [], []
    for k in ok:
        v, o = v_series[k], o_series[k]
        veh, vsh = f(v["elapsed_hours"]), f(v["stock_hours"])
        oeh, osh = f(o["elapsed_hours"]), f(o["stock_hours"])
        if not veh or not oeh:
            continue
        vf, of = vsh / veh, osh / oeh
        fr_d.append(vf - of)
        fr_pairs.append((k, vf, of, vf - of))
    describe("delta fraction", fr_d)
    for tol in (0.01, 0.05, 0.10):
        n = sum(1 for d in fr_d if abs(d) <= tol)
        print(f"  |delta| <= {tol:<5}          {n}/{len(fr_d)} = {100.0*n/max(1,len(fr_d)):.1f}%")

    print("\n  worst 12 by |delta fraction|:")
    fr_pairs.sort(key=lambda t: -abs(t[3]))
    for (mid, pid), vf, of, d in fr_pairs[:12]:
        v = v_series[(mid, pid)]
        print(
            f"    {mid[:8]}/{pid[:8]}  view={vf:.3f} oracle={of:.3f} d={d:+.3f}  "
            f"cases A/B/C/D/X={v['n_case_a']}/{v['n_case_b']}/{v['n_case_c']}/{v['n_case_d']}/{v['n_case_x']}"
        )

    # ---------------------------------------------------------------- elapsed_hours
    print("\n[4] elapsed_hours - isolates the WINDOW difference from the SOURCE difference")
    eh_d = [
        f(v_series[k]["elapsed_hours"]) - f(o_series[k]["elapsed_hours"])
        for k in ok
        if f(v_series[k]["elapsed_hours"]) is not None
        and f(o_series[k]["elapsed_hours"]) is not None
    ]
    describe("delta (view-oracle) h", eh_d)
    if eh_d:
        from collections import Counter

        c = Counter(round(x, 2) for x in eh_d)
        print("  most common deltas (h):", c.most_common(6))

    # ---------------------------------------------------------------- numerator
    print("\n[5] NUMERATOR  units_30d_canonical vs oracle units_canon")
    un_same = un_diff = un_null = 0
    diffs = []
    for k in ok:
        vu, ou = v_series[k]["units_30d_canonical"], o_series[k].get("units_canon")
        if vu is None or ou is None:
            un_null += 1
            continue
        if abs(float(vu) - float(ou)) < 1e-9:
            un_same += 1
        else:
            un_diff += 1
            diffs.append((k, float(vu), float(ou)))
    print(f"  identical {un_same}   different {un_diff}   one-side-null {un_null}")
    diffs.sort(key=lambda t: -abs(t[1] - t[2]))
    for (mid, pid), vu, ou in diffs[:8]:
        print(f"    {mid[:8]}/{pid[:8]}  view={vu:g} oracle={ou:g} d={vu-ou:+g}")

    # ---------------------------------------------------------------- case mix
    print("\n[6] CASE MIX (cells)")
    vc = {c: sum(int(r[f"n_case_{c.lower()}"]) for r in view) for c in "ABCDX"}
    oc = oracle["cases"]
    print(f"  view   A={vc['A']} B={vc['B']} C={vc['C']} D={vc['D']} X={vc['X']}")
    print(
        f"  oracle A={oc['A']} B={oc['B']} C={oc['C']} D={oc['D']} X={oc['X_absent']}"
    )

    # ---------------------------------------------------------------- status
    print("\n[7] velocity_status (view only - the oracle has no such concept)")
    from collections import Counter

    print(" ", dict(Counter(r["velocity_status"] for r in view)))
    oos = [r for r in view if r["velocity_status"] == "out_of_canonical_scope"]
    print(f"  out_of_canonical_scope: {len(oos)}/{len(view)} = {100.0*len(oos)/len(view):.1f}%")
    print(f"    ...of which the oracle DID have a velocity: "
          f"{sum(1 for r in oos if (r['machine_id'],r['pod_product_id']) in o_series and o_series[(r['machine_id'],r['pod_product_id'])].get('velocity_instock') is not None)}")
    print(f"    ...machines affected: {len({r['machine_id'] for r in oos})}")
    print(f"    ...units_window carried by them: "
          f"{sum(float(r['units_window'] or 0) for r in oos):g}")

    # ---------------------------------------------------------------- verdict inputs
    print("\n[8] velocity_instock, where BOTH sides produced one")
    vr = []
    for k in ok:
        v, o = v_series[k]["velocity_instock"], o_series[k].get("velocity_instock")
        if v is None or o is None or float(o) == 0:
            continue
        vr.append(float(v) / float(o))
    describe("ratio view/oracle", vr)
    if vr:
        n = sum(1 for r in vr if 0.9 <= r <= 1.1)
        print(f"  within +/-10%              {n}/{len(vr)} = {100.0*n/len(vr):.1f}%")


if __name__ == "__main__":
    main()
