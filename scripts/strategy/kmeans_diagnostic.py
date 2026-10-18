#!/usr/bin/env python3
"""PRD-142a 4.3 step 1: K-means diagnostic over machine_features.

Discovers machine archetypes on the Boonz population (machines under 90
days excluded). Diagnostic only: its output is committed as
docs/prds/PRD-142-kmeans.md and the archetype rules are then written by hand
into machine_archetypes. Standard library only (no numpy on this machine).

Reads the latest machine_features snapshot through the Supabase REST API with
the service key (SUPABASE_URL and SUPABASE_SERVICE_KEY from the environment or
.env). Prints markdown.

Usage: python3 scripts/strategy/kmeans_diagnostic.py [--population boonz] [--kmin 3] [--kmax 6]
"""

import argparse
import json
import math
import os
import random
import statistics
import urllib.request

FEATURES = [
    "rev_day_90",
    "units_day_90",
    "ticket_90",
    "card_share_90",
    "peak_hour_share_90",
    "weekend_share_90",
    "weekday_lunch_share_90",
    "drinks_share_90",
    "top5_shelf_share_90",
    "dead_shelf_pct_90",
    "cv_monthly_12",
]


def load_env():
    env = dict(os.environ)
    path = os.path.join(os.path.dirname(__file__), "..", "..", ".env")
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    return env


def rest_get(env, path):
    url = env["SUPABASE_URL"].rstrip("/") + "/rest/v1/" + path
    key = env["SUPABASE_SERVICE_KEY"]
    req = urllib.request.Request(url, headers={"apikey": key, "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read())


def fetch(env, population):
    latest = rest_get(env, "machine_features?select=as_of&order=as_of.desc&limit=1")[0]["as_of"]
    rows = rest_get(
        env,
        "machine_features?select=machine_id,age_days,population,peak_hours_90,"
        + ",".join(FEATURES)
        + f"&as_of=eq.{latest}&population=eq.{population}&limit=10000",
    )
    names = {
        m["machine_id"]: m["official_name"]
        for m in rest_get(env, "machines?select=machine_id,official_name&limit=10000")
    }
    for r in rows:
        r["name"] = names.get(r["machine_id"], r["machine_id"])
    return latest, rows


def standardize(rows):
    cols = {}
    for f in FEATURES:
        vals = [float(r[f]) for r in rows if r[f] is not None]
        med = statistics.median(vals) if vals else 0.0
        filled = [float(r[f]) if r[f] is not None else med for r in rows]
        mu = statistics.mean(filled)
        sd = statistics.pstdev(filled) or 1.0
        cols[f] = {"median": med, "mean": mu, "sd": sd, "imputed": sum(1 for r in rows if r[f] is None)}
        for r, v in zip(rows, filled):
            r.setdefault("_z", {})[f] = (v - mu) / sd
            r.setdefault("_raw", {})[f] = v
    return cols


def dist2(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b))


def kmeans(points, k, seed, iters=100):
    rnd = random.Random(seed)
    # k-means++ seeding
    centers = [points[rnd.randrange(len(points))]]
    while len(centers) < k:
        d = [min(dist2(p, c) for c in centers) for p in points]
        total = sum(d)
        if total == 0:
            centers.append(points[rnd.randrange(len(points))])
            continue
        r = rnd.random() * total
        acc = 0.0
        for p, w in zip(points, d):
            acc += w
            if acc >= r:
                centers.append(p)
                break
    labels = [0] * len(points)
    for _ in range(iters):
        new = [min(range(k), key=lambda j: dist2(p, centers[j])) for p in points]
        if new == labels and _ > 0:
            break
        labels = new
        for j in range(k):
            members = [p for p, l in zip(points, labels) if l == j]
            if members:
                centers[j] = [statistics.mean(c) for c in zip(*members)]
    inertia = sum(dist2(p, centers[l]) for p, l in zip(points, labels))
    return labels, centers, inertia


def silhouette(points, labels, k):
    scores = []
    for i, p in enumerate(points):
        own = [math.sqrt(dist2(p, q)) for j, q in enumerate(points) if labels[j] == labels[i] and j != i]
        if not own:
            scores.append(0.0)
            continue
        a = statistics.mean(own)
        b = min(
            statistics.mean([math.sqrt(dist2(p, q)) for j, q in enumerate(points) if labels[j] == c])
            for c in range(k)
            if c != labels[i] and any(l == c for l in labels)
        )
        scores.append((b - a) / max(a, b) if max(a, b) > 0 else 0.0)
    return statistics.mean(scores)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--population", default="boonz")
    ap.add_argument("--kmin", type=int, default=3)
    ap.add_argument("--kmax", type=int, default=6)
    ap.add_argument("--n-init", type=int, default=200)
    args = ap.parse_args()

    env = load_env()
    as_of, rows = fetch(env, args.population)
    excluded = sorted(r["name"] for r in rows if (r["age_days"] or 0) < 90)
    rows = [r for r in rows if (r["age_days"] or 0) >= 90]
    rows.sort(key=lambda r: r["name"])
    cols = standardize(rows)
    points = [[r["_z"][f] for f in FEATURES] for r in rows]

    print(f"# K-means diagnostic, population {args.population}, machine_features as_of {as_of}\n")
    print(f"Machines clustered: {len(rows)}. Excluded (age under 90 days): {', '.join(excluded) or 'none'}.\n")
    print("Features standardised to z-scores; NULLs imputed with the population median:")
    print("| feature | median | mean | sd | imputed |")
    print("| --- | --- | --- | --- | --- |")
    for f in FEATURES:
        c = cols[f]
        print(f"| {f} | {c['median']:.3f} | {c['mean']:.3f} | {c['sd']:.3f} | {c['imputed']} |")
    print()

    results = {}
    for k in range(args.kmin, args.kmax + 1):
        best = None
        for seed in range(args.n_init):
            labels, centers, inertia = kmeans(points, k, seed)
            if len(set(labels)) < k:
                continue
            if best is None or inertia < best[2] - 1e-9:
                best = (labels, centers, inertia)
        labels, centers, inertia = best
        sil = silhouette(points, labels, k)
        results[k] = (labels, centers, inertia, sil)

    print("## Silhouette per k\n")
    print("| k | silhouette | inertia |")
    print("| --- | --- | --- |")
    for k, (_, _, inertia, sil) in results.items():
        print(f"| {k} | {sil:.3f} | {inertia:.2f} |")
    print()

    for k, (labels, centers, inertia, sil) in results.items():
        print(f"## k = {k} (silhouette {sil:.3f})\n")
        print("Centroids in raw units (mean of members):\n")
        print("| cluster | n | " + " | ".join(FEATURES) + " | machines |")
        print("| --- | --- | " + " | ".join("---" for _ in FEATURES) + " | --- |")
        for j in range(k):
            members = [r for r, l in zip(rows, labels) if l == j]
            means = [statistics.mean(r["_raw"][f] for r in members) for f in FEATURES]
            print(
                f"| {j} | {len(members)} | "
                + " | ".join(f"{m:.2f}" for m in means)
                + " | "
                + ", ".join(r["name"] for r in members)
                + " |"
            )
        print()


if __name__ == "__main__":
    main()
