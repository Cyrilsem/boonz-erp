#!/usr/bin/env python3
"""
check_prod_repo_drift.py — RC-15 CI guard: detect prod<->repo drift for the core RPC set.

Compares the LIVE pg_get_functiondef body of each function in RPC_SET against the
latest definition found in the repo migration files (per function name + arg count,
latest migration filename wins). Bodies are normalized before hashing:
  - strip `--` line comments (quote-aware; MCP apply_migration strips comments, so
    live bodies never contain them while repo files do)
  - collapse all whitespace, lowercase
so comment/formatting-only differences never alert.

Modes
-----
1) Direct DB (needs psycopg2 + env SUPABASE_DB_URL):
     SUPABASE_DB_URL=postgres://... python3 scripts/check_prod_repo_drift.py

2) Offline via MCP-exported defs (no DB connection, no dependencies):
     python3 scripts/check_prod_repo_drift.py --from-json livedefs.json
   where livedefs.json is the JSON array produced by running this query through
   the Supabase MCP `execute_sql` (or psql -At):
     select json_agg(json_build_object(
              'proname', p.proname,
              'args',    pg_get_function_identity_arguments(p.oid),
              'def',     pg_get_functiondef(p.oid)))
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = any(array[<RPC_SET>]);

Options
-------
  --migrations-dir DIR   repo migrations dir (repeatable; later dirs override earlier
                         ones only via filename ordering). Default: supabase/migrations
                         relative to the repo root (parent of this script's dir).
  --from-json FILE       offline mode (see above). '-' reads stdin.
  --json                 emit machine-readable report to stdout.

Exit codes: 0 = no drift, 1 = drift found, 2 = usage/environment error.

Known limitation: patch-style migrations (DO blocks that fetch the live def and
replace() hunks, e.g. fixCE / fixD2 of 2026-07-14) cannot be evaluated statically.
Functions whose latest repo change is patch-style will report against the last FULL
definition; whitelist their expected live hash in PATCHED_EXPECTED below after each
intentional patch migration.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from glob import glob

# The RC-15 core RPC set (Task-2 scope, incl. %stitch% planner fns found live 2026-07-18).
RPC_SET = [
    "pick_machines_for_refill",
    "build_draft_for_confirmed",
    "engine_add_pod",
    "engine_swap_pod",
    "engine_finalize_pod",
    "stitch_pod_to_boonz",
    "confirm_stitched_plan",
    "restitch_after_edits",
    "reset_and_restitch",
    "reopen_stitched_rows",
    "push_plan_to_dispatch",
    "reset_approved_undispatched",
    "approve_refill_plan",
    "pack_dispatch_line",
    "receive_dispatch_line",
    "return_dispatch_line",
    "edit_dispatch_qty",
    "edit_dispatch_product",
    "add_dispatch_row",
    "write_refill_plan",
    "confirm_machine_packed",
    "record_actual_refill",
    "adjust_warehouse_stock",
    "adjust_pod_inventory",
    "apply_inventory_correction",
    "release_wh_quarantine",
    "set_machine_warehouse",
    "repack_machine",
]

# proname -> {normalized-body md5 that is EXPECTED live although produced by a
# patch-style migration rather than a full repo definition}. Maintain after each
# intentional patch migration (see docstring).
PATCHED_EXPECTED: dict[str, set[str]] = {
    # fixCE_stitch_provenance_and_dedup (20260714234441) patches these on top of
    # p0_fix11 / p0_fix3 bases; hashes captured from prod 2026-07-18 (RC-15):
    "stitch_pod_to_boonz": {"2345f39dd1a2ec71192771d7a5fe9f86"},
    "write_refill_plan": {"8854aa44d0335854ac18fab387c45a90"},
}


def strip_line_comments(sql: str) -> str:
    """Remove -- comments outside single-quoted strings (line-based, quote-aware)."""
    out = []
    for line in sql.split("\n"):
        in_quote = False
        cut = len(line)
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == "'":
                in_quote = not in_quote
            elif ch == "-" and not in_quote and i + 1 < len(line) and line[i + 1] == "-":
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


def normalize(sql: str) -> str:
    return re.sub(r"\s+", " ", strip_line_comments(sql)).strip().lower()


def body_hash(body: str) -> str:
    return hashlib.md5(normalize(body).encode()).hexdigest()


def extract_dollar_body(text: str) -> str | None:
    """Outermost dollar-quoted body after AS (as emitted by pg_get_functiondef)."""
    m = re.search(r"AS\s+(\$[A-Za-z_]*\$)", text)
    if not m:
        return None
    tag = m.group(1)
    end = text.find(tag, m.end())
    if end < 0:
        return None
    return text[m.end():end]


def count_top_level_args(argstr: str) -> int:
    depth = 0
    n = 0
    in_quote = False
    has_any = bool(argstr.strip())
    for ch in argstr:
        if ch == "'":
            in_quote = not in_quote
        elif in_quote:
            continue
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "," and depth == 0:
            n += 1
    return n + 1 if has_any else 0


def repo_definitions(migration_dirs):
    """{(proname, nargs): (filename, body)} — latest migration filename wins."""
    files = []
    for d in migration_dirs:
        files.extend(glob(os.path.join(d, "*.sql")))
    # skip repo-ahead / held drafts
    files = [f for f in files if not os.path.basename(f).startswith(("_DRAFT", "_HELD", "_ROLLBACK"))]
    files.sort(key=os.path.basename)  # version-prefixed names sort chronologically
    defs = {}
    name_alt = "|".join(re.escape(n) for n in RPC_SET)
    pat = re.compile(
        r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?(" + name_alt + r")\s*\(",
        re.I,
    )
    for path in files:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in pat.finditer(text):
            name = m.group(1).lower()
            rest = text[m.start():]
            # arg list: up to matching close paren of the signature
            depth = 0
            sig_end = None
            for i, ch in enumerate(rest):
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        sig_end = i
                        break
            if sig_end is None:
                continue
            argstr = rest[rest.index("(") + 1: sig_end]
            nargs = count_top_level_args(argstr)
            body = extract_dollar_body(rest)
            if body is None:
                continue
            defs[(name, nargs)] = (os.path.basename(path), body)
    return defs


def live_definitions_from_db(db_url):
    try:
        import psycopg2  # type: ignore
    except ImportError:
        print("ERROR: psycopg2 not installed; use --from-json instead.", file=sys.stderr)
        sys.exit(2)
    conn = psycopg2.connect(db_url)
    cur = conn.cursor()
    cur.execute(
        """
        select p.proname, pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = any(%s)
        """,
        (RPC_SET,),
    )
    rows = [{"proname": r[0], "args": r[1], "def": r[2]} for r in cur.fetchall()]
    conn.close()
    return rows


def live_definitions_from_json(path):
    raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    data = json.loads(raw)
    if isinstance(data, dict):  # tolerate {"result": [...]} style exports
        for v in data.values():
            if isinstance(v, list):
                data = v
                break
    if not isinstance(data, list):
        print("ERROR: --from-json expects a JSON array of {proname,args,def}.", file=sys.stderr)
        sys.exit(2)
    return data


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--migrations-dir", action="append", default=None)
    ap.add_argument("--from-json", metavar="FILE")
    ap.add_argument("--defs-json", dest="from_json_alias", metavar="FILE",
                    help="alias for --from-json")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    from_json = args.from_json or args.from_json_alias
    if from_json:
        live = live_definitions_from_json(from_json)
    else:
        db_url = os.environ.get("SUPABASE_DB_URL")
        if not db_url:
            print("ERROR: set SUPABASE_DB_URL or pass --from-json FILE.", file=sys.stderr)
            sys.exit(2)
        live = live_definitions_from_db(db_url)

    if args.migrations_dir:
        mig_dirs = args.migrations_dir
    else:
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        mig_dirs = [os.path.join(repo_root, "supabase", "migrations")]
    for d in mig_dirs:
        if not os.path.isdir(d):
            print(f"ERROR: migrations dir not found: {d}", file=sys.stderr)
            sys.exit(2)

    repo = repo_definitions(mig_dirs)
    wanted = set(n.lower() for n in RPC_SET)
    seen = set()
    drift, ok, notes = [], [], []

    for row in live:
        name = row["proname"].lower()
        if name not in wanted:
            continue
        seen.add(name)
        nargs = count_top_level_args(row.get("args", "") or "")
        body = extract_dollar_body(row["def"]) or row["def"]
        h = body_hash(body)
        key = (name, nargs)
        label = f"{name}/{nargs}args"
        if h in PATCHED_EXPECTED.get(name, ()):  # patch-style whitelist
            ok.append((label, "matches PATCHED_EXPECTED whitelist"))
            continue
        if key not in repo:
            # fall back: any arity of the same name (defaults can shift arity)
            cands = {k: v for k, v in repo.items() if k[0] == name}
            if not cands:
                drift.append((label, "NO definition of this function in any repo migration", h, None))
                continue
            best = max(cands.items(), key=lambda kv: kv[1][0])
            key = best[0]
        fname, rbody = repo[key]
        if body_hash(rbody) == h:
            ok.append((label, f"matches {fname}"))
        else:
            # does it match an OLDER definition? (helps localize when drift began)
            older = None
            for (n2, _), (f2, b2) in repo.items():
                if n2 == name and body_hash(b2) == h:
                    older = f2
                    break
            drift.append((label, f"live body != latest repo def ({fname})"
                          + (f"; live matches older file {older}" if older else ""), h, fname))

    missing_live = sorted(wanted - seen)

    if args.json:
        print(json.dumps({
            "ok": [{"fn": a, "detail": b} for a, b in ok],
            "drift": [{"fn": a, "detail": b, "live_md5": c, "repo_file": d} for a, b, c, d in drift],
            "missing_live": missing_live,
        }, indent=2))
    else:
        for a, b in sorted(ok):
            print(f"OK    {a:45s} {b}")
        for a, b, c, d in sorted(drift):
            print(f"DRIFT {a:45s} {b}  (live md5 {c})")
        for n in missing_live:
            print(f"WARN  {n:45s} in RPC_SET but not present in live export/DB")
        print(f"\n{len(ok)} ok, {len(drift)} drift, {len(missing_live)} missing-live")
    sys.exit(1 if drift else 0)


if __name__ == "__main__":
    main()
