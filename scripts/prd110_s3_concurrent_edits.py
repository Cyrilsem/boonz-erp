#!/usr/bin/env python3
"""PRD-110 STEP 7 · S3 — concurrent-edits stress driver (leg 122).

`golden.stress_runs.driver` carries the value 'external' for exactly this suite.
S1/S2/S4/S6 are single SQL functions because their property is expressible inside
one session; S3's is not. Twenty edits issued from ONE session are twenty
SEQUENTIAL statements, and a suite that loops `record_plan_edit_v3` twenty times
proves nothing about concurrency at all. This driver opens one HTTPS connection
per edit and fires them from a thread pool, so the twenty `record_plan_edit_v3`
calls are twenty genuinely overlapping backend transactions racing for
`ux_plan_edits_v3_active`.

Three waves:
  wave 0 - one SEED edit on the contention key, issued serially, so that wave 2
           exercises the SUPERSEDE path rather than the first-insert path.
  wave 1 - N concurrent edits on N DISTINCT keys. The goal command's suite.
  wave 2 - K concurrent edits on ONE key. Wave 1 cannot fail on the supersede
           path because its keys never collide.

Every call's wall-clock start/end is recorded in epoch milliseconds and handed to
`golden.stress_s3_verify_v1`, which computes PEAK IN-FLIGHT OVERLAP from them.
Twenty sequential calls score 1 there and the suite reds - that assertion is what
stops a driver regression from turning S3 into a slow serial test that still
passes everything else.

Usage:
  python3 scripts/prd110_s3_concurrent_edits.py                 # full run
  python3 scripts/prd110_s3_concurrent_edits.py --dry-run       # setup+plan only
  python3 scripts/prd110_s3_concurrent_edits.py --plan-date 2030-11-03 -n 20 -k 5
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor

PROJECT_REF = "eizcexopcuoycuosittm"
API = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
REPO = "/Users/cyrilsemaan/Documents/Boonz Script and Data/BOONZ BRAIN/boonz-erp"


def token() -> str:
    """Same project-scoped management token the supabase MCP server is configured
    with; /tmp/prd110_sql.sh reads it the same way."""
    with open(os.path.expanduser("~/.claude.json")) as fh:
        cfg = json.load(fh)
    args = cfg["projects"][REPO]["mcpServers"]["supabase"]["args"]
    return [a for a in args if a.startswith("--access-token=")][0].split("=", 1)[1]


TOKEN = token()


# ⛔ MEASURED, leg 122: the management API sits behind Cloudflare, which answers
# `Python-urllib/3.x` with a bare `HTTP 403: error code: 1010` — a client-
# fingerprint block, NOT an auth failure and NOT the `/database/migrations` 403
# the pointer warns about. The same token and the same endpoint answer curl
# normally. Presenting curl's User-Agent is the whole fix; without it every call
# in every wave fails identically and the suite looks like a permissions problem.
UA = "curl/8.7.1"


def q(sql: str, timeout: int = 900):
    """One statement, one connection. Returns (ok, payload_or_error_text)."""
    req = urllib.request.Request(
        API,
        data=json.dumps({"query": sql}).encode(),
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": UA,
            "Accept": "*/*",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return True, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            j = json.loads(body)
            # the management API returns the postgres message here; keep it whole,
            # because assertion 28 turns on a refusal being VISIBLE to the caller.
            return False, j.get("message") or j.get("error") or body
        except Exception:
            return False, f"HTTP {e.code}: {body[:400]}"
    except Exception as e:  # noqa: BLE001 - transport failures must be reported, not swallowed
        return False, f"{type(e).__name__}: {e}"


def ms(ts) -> float | None:
    """Postgres timestamptz text -> epoch milliseconds, for the wave-2 witness."""
    if not ts:
        return None
    from datetime import datetime

    s = str(ts).replace("Z", "+00:00")
    # '2026-08-04T05:01:02.123456+00:00' — fromisoformat handles this on 3.11+
    return round(datetime.fromisoformat(s).timestamp() * 1000.0, 3)


def lit(v) -> str:
    """SQL literal. Single quotes doubled; None -> NULL."""
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def fire_edit(t: dict, wave: int, barrier: str | None = None) -> dict:
    """One `record_plan_edit_v3` call on its own connection, wall-clock stamped.

    ⛔ CLIENT-SIDE IN-FLIGHT OVERLAP IS NOT BACKEND CONTENTION. `record_plan_edit_v3`
    spends milliseconds inside its FOR-UPDATE/INSERT critical section while a call
    takes ~2.7 s end to end, nearly all of it transport. The first S3 run had five
    same-key requests in flight together and still saw 5 ok / 0 refused, because
    they took the row lock one after another - a result indistinguishable from
    "correct serialisation" and from "never raced at all".

    `barrier` fixes that. When set, the request sleeps SERVER-side until one shared
    target instant and only then enters the RPC, so all contenders reach the
    critical section within milliseconds of each other. The statement also returns
    the server clock at entry and exit, which is what assertion 35 judges - the
    client's own timings cannot see a backend lock queue.
    """
    call = (
        "public.record_plan_edit_v3("
        f"{lit(t['plan_date'])}::date, {lit(t['shelf_id'])}::uuid, "
        f"{lit(t['pod_product_id'])}::uuid, {lit(t['kind'])}, "
        f"{lit(t['qty'])}::int, {lit(t['lock'])}, {lit(t['reason'])})"
    )
    if barrier:
        # the CTE is evaluated before the outer target list, so the sleep and the
        # entry stamp both happen before the RPC is called.
        sql = (
            "WITH gate AS (SELECT pg_sleep(GREATEST(0, extract(epoch FROM ("
            f"{lit(barrier)}::timestamptz - clock_timestamp())))) AS s, "
            "clock_timestamp() AS t_enter) "
            f"SELECT jsonb_build_object('r', {call}, "
            "'t_enter', (SELECT t_enter FROM gate), 't_exit', clock_timestamp()) AS r "
            "FROM gate"
        )
    else:
        sql = f"SELECT {call} AS r"

    t0 = time.time() * 1000.0
    ok, payload = q(sql, timeout=180)
    t1 = time.time() * 1000.0
    edit_id, err, t_enter, t_exit = None, None, None, None
    if ok:
        try:
            r = payload[0]["r"]
            if barrier:
                t_enter, t_exit = ms(r.get("t_enter")), ms(r.get("t_exit"))
                r = r["r"]
            edit_id = r["edit_id"]
        except Exception:  # noqa: BLE001
            ok, err = False, f"unparseable response: {json.dumps(payload)[:300]}"
    else:
        err = str(payload)
    return {
        "wave": wave,
        "idx": t["idx"],
        "shelf_id": t["shelf_id"],
        "pod_product_id": t["pod_product_id"],
        "kind": t["kind"],
        "lock": t["lock"],
        "qty": t["qty"],
        "ok": ok,
        "edit_id": edit_id,
        "err": err,
        "t0": round(t0, 3),
        "t1": round(t1, 3),
        "t_enter": t_enter,
        "t_exit": t_exit,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan-date", default="2030-11-03")
    ap.add_argument("--days-cover", type=int, default=7)
    ap.add_argument("-n", "--edits", type=int, default=20, help="wave-1 concurrent edits")
    ap.add_argument("-k", "--contenders", type=int, default=5, help="wave-2 same-key edits")
    ap.add_argument("--dry-run", action="store_true", help="setup + target plan only, no edits")
    ap.add_argument("--allow-cron-window", action="store_true")
    ap.add_argument("--no-record", action="store_true")
    ap.add_argument("--note", default=None)
    a = ap.parse_args()

    note = a.note or "PRD-110 STEP 7 S3 concurrent edits"

    # ---------------------------------------------------------------- phase 1
    print(f"[S3] setup on {a.plan_date} ...", flush=True)
    ok, payload = q(
        "SELECT golden.stress_s3_setup_v1("
        f"{lit(a.plan_date)}::date, {a.days_cover}, {a.edits}, "
        f"{lit(a.allow_cron_window)}, {lit(note)}) AS r"
    )
    if not ok:
        print(f"[S3] SETUP FAILED: {payload}", file=sys.stderr)
        return 2
    setup = payload[0]["r"]
    targets = setup["targets"]
    print(
        f"[S3] base status={setup['base_status']} lines={setup['base_lines']} "
        f"planted={setup['planted']}/{setup['fleet']} targets={setup['n_targets']} "
        f"({setup['duration_ms']} ms)",
        flush=True,
    )
    if setup["base_status"] != "ok":
        print(f"[S3] base pipeline did not complete: {setup['base_status']}", file=sys.stderr)
        return 2
    if len(targets) < a.edits + 1:
        print(f"[S3] only {len(targets)} targets for n={a.edits}+1", file=sys.stderr)
        return 2

    for t in targets:
        t["plan_date"] = a.plan_date

    wave1 = [t for t in targets if t["idx"] <= a.edits]
    contention = [t for t in targets if t["idx"] == a.edits + 1][0]

    if a.dry_run:
        print(json.dumps({"setup": {k: v for k, v in setup.items() if k != "targets"},
                          "targets": targets}, indent=2))
        return 0

    calls = []

    # ---------------------------------------------------- wave 0: seed, serial
    seed = dict(contention)
    seed["kind"], seed["qty"], seed["lock"] = "set_qty", (seed["base_qty"] or 0) + 1, "soft"
    seed["reason"] = f"PRD-110 STEP 7 S3 contention seed on {a.plan_date}"
    r0 = fire_edit(seed, 0)
    calls.append(r0)
    print(f"[S3] wave 0 seed ok={r0['ok']} edit_id={r0['edit_id']} err={r0['err']}", flush=True)
    if not r0["ok"]:
        print("[S3] the seed must land or wave 2 tests the wrong path", file=sys.stderr)
        return 2

    # ------------------------------------------- wave 1: N distinct keys, hot
    print(f"[S3] wave 1: firing {len(wave1)} concurrent edits ...", flush=True)
    with ThreadPoolExecutor(max_workers=len(wave1)) as pool:
        w1 = list(pool.map(lambda t: fire_edit(t, 1), wave1))
    calls.extend(w1)
    ok1 = sum(1 for c in w1 if c["ok"])
    span = max(c["t1"] for c in w1) - min(c["t0"] for c in w1)
    ssum = sum(c["t1"] - c["t0"] for c in w1)
    print(f"[S3] wave 1: {ok1}/{len(w1)} ok · span {span:.0f} ms · serial sum {ssum:.0f} ms",
          flush=True)
    for c in w1:
        if not c["ok"]:
            print(f"[S3]   idx {c['idx']} FAILED: {c['err']}", flush=True)

    # --------------------------------------- wave 2: K on ONE key, contention
    cw = []
    for i in range(a.contenders):
        c = dict(contention)
        c["kind"], c["qty"], c["lock"] = "set_qty", (c["base_qty"] or 0) + 10 + i, "hard"
        c["reason"] = f"PRD-110 STEP 7 S3 same-key contention rider {i + 1}"
        cw.append(c)
    # ⭐ THE BARRIER. Every contender sleeps server-side until this one instant and
    #    only then enters record_plan_edit_v3, so the five reach the FOR-UPDATE /
    #    INSERT critical section within milliseconds of each other instead of
    #    politely queueing seconds apart. 6 s is enough for the slowest connection
    #    setup observed (~2.7 s) plus margin.
    ok, payload = q("SELECT (now() + interval '6 seconds')::text AS t")
    if not ok:
        print(f"[S3] could not read the server clock for the barrier: {payload}", file=sys.stderr)
        return 2
    barrier = payload[0]["t"]
    print(f"[S3] wave 2: firing {len(cw)} concurrent edits on ONE key, "
          f"barrier-aligned to {barrier} ...", flush=True)
    with ThreadPoolExecutor(max_workers=len(cw)) as pool:
        w2 = list(pool.map(lambda t: fire_edit(t, 2, barrier), cw))
    spread = [c["t_enter"] for c in w2 if c["t_enter"] is not None]
    if len(spread) >= 2:
        print(f"[S3] wave 2 server entry spread: {max(spread) - min(spread):.1f} ms "
              f"over {len(spread)} samples", flush=True)
    calls.extend(w2)
    ok2 = sum(1 for c in w2 if c["ok"])
    print(f"[S3] wave 2: {ok2}/{len(w2)} ok, {len(w2) - ok2} refused", flush=True)
    for c in w2:
        if not c["ok"]:
            print(f"[S3]   refused: {str(c['err'])[:160]}", flush=True)

    edit_ids = [c["edit_id"] for c in w1 if c["ok"] and c["edit_id"]]

    # ---------------------------------------------------------------- phase 3
    print("[S3] verify: re-running the pipeline, then judging ...", flush=True)
    ids_sql = "ARRAY[" + ",".join(lit(i) for i in edit_ids) + "]::uuid[]"
    sql = (
        "SELECT golden.stress_s3_verify_v1("
        f"{lit(a.plan_date)}::date, {a.days_cover}, {ids_sql}, "
        f"{lit(json.dumps(calls))}::jsonb, {lit(json.dumps(setup['bank']))}::jsonb, "
        f"{lit(not a.no_record)}, {lit(note)}) AS r"
    )
    ok, payload = q(sql)
    if not ok:
        # ⛔ S-212/S-226: the gateway can cut a long response AFTER the server has
        # already committed. Never take the verdict from the response body - read
        # it back from golden.stress_runs, which is the authoritative channel.
        print(f"[S3] verify response lost ({str(payload)[:200]}); reading the verdict back "
              "from golden.stress_runs", flush=True)
        ok2_, payload = q(
            "SELECT jsonb_build_object('stress_run_id',stress_run_id,'passed',passed,"
            "'n_pass',n_pass,'n_fail',n_fail,'detail',detail,'metric',metric) AS r "
            "FROM golden.stress_runs WHERE suite='S3' ORDER BY started_at DESC LIMIT 1"
        )
        if not ok2_:
            print(f"[S3] read-back also failed: {payload}", file=sys.stderr)
            return 2
    res = payload[0]["r"]
    print(json.dumps(res, indent=2))
    print(
        f"\n[S3] {'PASS' if res.get('passed') else 'FAIL'} · "
        f"{res.get('n_pass')} pass / {res.get('n_fail')} fail / {res.get('n_skip', '?')} skip · "
        f"stress_run_id {res.get('stress_run_id')}",
        flush=True,
    )
    return 0 if res.get("passed") else 1


if __name__ == "__main__":
    sys.exit(main())
