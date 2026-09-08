#!/usr/bin/env python3
"""
check_migration_parity.py — PRD-121 T6b: fail fast when a migration lands on
prod without a matching file in supabase/migrations/ (the exact discipline
break T1 of this PRD had to reconstruct 5 migrations after).

Compares remote supabase_migrations.schema_migrations (version >= 20260615000000)
against supabase/migrations/*.sql by name-substring: for every remote row not
covered by the permanent exceptions below, at least one local filename's
name-portion (everything after its own <timestamp>_ prefix) must appear as a
substring of the remote row's `name` column, or vice versa, after both sides
are lowercased and stripped of any leading digit-run prefix. Substring, not
exact match, because MCP-applied migrations often echo an embedded (and
sometimes stale) timestamp inside their own `name` string rather than using
the remote `version` as their prefix — see PRD-072's prd053a false-positive
note. Perfect name matching is NOT possible for two known historical rows,
which is why they are permanent, hardcoded exceptions rather than something
this script tries to solve generically:

  - 20260623210108 (name starts "20260623120000_prd053a_stitch_remove_..."):
    local file is 20260624130000_prd053a_stitch_v28_remove_conservation_planqty.sql
    — the "_v28_" segment breaks substring containment even after normalizing.
  - 20260831041717 (prd118_i_commitment_expose_breakdown): no separate file by
    design (D2) — covered by the combined 20260831041717_prd118_i_commitment_
    batch_grain_and_breakdown.sql, whose own local name differs from the remote
    name enough that a generic substring rule would still miss it.

Modes (mirrors scripts/check_prod_repo_drift.py's proven pattern — this repo
has no local DB CLI/credentials, see CLAUDE.md):

1) Direct DB (needs psycopg2 + env SUPABASE_DB_URL):
     SUPABASE_DB_URL=postgres://... python3 scripts/check_migration_parity.py

2) Offline via MCP-exported manifest (no DB connection, no dependencies):
     python3 scripts/check_migration_parity.py --from-tsv manifest.tsv
   where manifest.tsv has one "version<TAB>name" row per line, produced via
   the Supabase MCP execute_sql (or psql -At -F$'\t'):
     select version, name from supabase_migrations.schema_migrations
     where version >= '20260615000000' order by version;

Exit codes: 0 = no drift, 1 = drift found (untracked prod migration), 2 = usage/env error.
"""

import argparse
import os
import re
import sys
from glob import glob

CUTOFF_VERSION = "20260615000000"

# Permanent exceptions (D2-class): remote version -> why. See docstring.
EXCEPTIONS = {
    "20260623210108": "prd053a — local file 20260624130000_prd053a_stitch_v28_remove_conservation_planqty.sql, name drift (_v28_) breaks substring matching",
    "20260831041717": "prd118_i_commitment_expose_breakdown — covered by the combined 20260831041717_prd118_i_commitment_batch_grain_and_breakdown.sql (D2, second of its class after prd053a)",
}

FILENAME_RE = re.compile(r"^(\d{14})_(.+)\.sql$")


def normalize(s: str) -> str:
    s = s.lower()
    s = re.sub(r"^\d+_", "", s)  # strip one leading digit-run prefix, if any
    s = re.sub(r"[^a-z0-9]+", "_", s).strip("_")
    return s


def local_name_cores(migrations_dir: str):
    cores = []
    for path in sorted(glob(os.path.join(migrations_dir, "*.sql"))):
        base = os.path.basename(path)
        if base.startswith(("_DRAFT", "_HELD", "_ROLLBACK")):
            continue
        m = FILENAME_RE.match(base)
        if not m:
            continue  # non-conforming filenames are CLAUDE.md's own known footgun; not this script's job
        cores.append((base, normalize(m.group(2))))
    return cores


def remote_rows_from_tsv(path: str):
    raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    rows = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            print(f"WARN  skipping malformed manifest line: {line!r}", file=sys.stderr)
            continue
        rows.append((parts[0].strip(), parts[1].strip()))
    return rows


def remote_rows_from_db(db_url: str):
    try:
        import psycopg2  # type: ignore
    except ImportError:
        print("ERROR: psycopg2 not installed; use --from-tsv instead.", file=sys.stderr)
        sys.exit(2)
    conn = psycopg2.connect(db_url)
    cur = conn.cursor()
    cur.execute(
        "SELECT version, name FROM supabase_migrations.schema_migrations "
        "WHERE version >= %s ORDER BY version",
        (CUTOFF_VERSION,),
    )
    rows = cur.fetchall()
    conn.close()
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--migrations-dir", default=None)
    ap.add_argument("--from-tsv", metavar="FILE", help="offline mode; '-' reads stdin")
    args = ap.parse_args()

    if args.migrations_dir:
        mig_dir = args.migrations_dir
    else:
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        mig_dir = os.path.join(repo_root, "supabase", "migrations")
    if not os.path.isdir(mig_dir):
        print(f"ERROR: migrations dir not found: {mig_dir}", file=sys.stderr)
        sys.exit(2)

    if args.from_tsv:
        remote = remote_rows_from_tsv(args.from_tsv)
    else:
        db_url = os.environ.get("SUPABASE_DB_URL")
        if not db_url:
            print("ERROR: set SUPABASE_DB_URL or pass --from-tsv FILE.", file=sys.stderr)
            sys.exit(2)
        remote = remote_rows_from_db(db_url)

    local = local_name_cores(mig_dir)
    missing = []
    checked = 0
    excepted = 0

    for version, name in remote:
        if version < CUTOFF_VERSION:
            continue
        if version in EXCEPTIONS:
            excepted += 1
            continue
        checked += 1
        remote_core = normalize(name)
        if any(remote_core in local_core or local_core in remote_core for _, local_core in local):
            continue
        missing.append((version, name))

    for version, name in missing:
        print(f"MISSING  version={version}  name={name}  -- applied on prod, no matching file in supabase/migrations/")
    print(f"\n{checked} checked, {len(missing)} missing, {excepted} excepted (permanent D2-class), {len(local)} local files scanned")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
