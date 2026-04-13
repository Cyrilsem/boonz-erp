"""
local_server.py — Boonz Refill Local Server
Bridges Cowork skill → local Python engine with real network access.

Start:  python -m engines.refill.local_server
Port:   8765 (override with BOONZ_LOCAL_PORT env var)
"""
from __future__ import annotations

import os
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv
load_dotenv()

try:
    from fastapi import FastAPI, Query
    from fastapi.responses import JSONResponse
    import uvicorn
except ImportError:
    subprocess.check_call([
        sys.executable, "-m", "pip", "install",
        "fastapi", "uvicorn[standard]", "--quiet"
    ])
    from fastapi import FastAPI, Query
    from fastapi.responses import JSONResponse
    import uvicorn

app = FastAPI(title="Boonz Refill Local Server", version="1.0.0")

REPO_ROOT = Path(__file__).parents[2]  # boonz-erp root


def _resolve_date(date_arg: str) -> str:
    """Resolve 'today', 'tomorrow', or passthrough ISO date."""
    today = date.today()
    if date_arg == "today":
        return today.isoformat()
    if date_arg == "tomorrow" or not date_arg:
        return (today + timedelta(days=1)).isoformat()
    return date_arg  # already ISO


def _run(cmd: list[str], timeout: int) -> tuple[bool, str]:
    """Run subprocess, return (success, output)."""
    try:
        r = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        output = r.stdout + (f"\nSTDERR: {r.stderr}" if r.stderr.strip() else "")
        return r.returncode == 0, output.strip()
    except subprocess.TimeoutExpired:
        return False, f"Timed out after {timeout}s"
    except Exception as e:
        return False, str(e)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "time": datetime.now(timezone.utc).isoformat(),
        "repo": str(REPO_ROOT),
    }


@app.get("/run-refill")
def run_refill(
    filter: str = Query(default="all"),
    date: str = Query(default="tomorrow"),
):
    resolved_date = _resolve_date(date)
    ts = lambda: datetime.now().strftime("%H:%M:%S")

    # ── Step 1: Weimi fetch ───────────────────────────────────────────────────
    print(f"\n[{ts()}] Step 1 — fetch_weimi_data (filter={filter})")

    # Single machine fetch uses --machine flag; group/all uses no args
    # Check if filter is an exact machine name (contains '-' and uppercase)
    is_exact_machine = (
        filter != "all"
        and "-" in filter
        and filter == filter.upper()
    )

    if is_exact_machine:
        fetch_cmd = [sys.executable, "-m", "engines.refill.fetch_weimi_data",
                     "--machine", filter]
    else:
        fetch_cmd = [sys.executable, "-m", "engines.refill.fetch_weimi_data"]

    ok, fetch_output = _run(fetch_cmd, timeout=120)
    print(fetch_output)

    if not ok:
        return JSONResponse(status_code=500, content={
            "step": "fetch_weimi_data",
            "error": fetch_output,
            "message": "❌ Weimi fetch failed — plan not generated. Check .env credentials.",
        })

    print(f"[{ts()}] ✅ Weimi fetch complete")

    # ── Step 2: Engine ────────────────────────────────────────────────────────
    print(f"[{ts()}] Step 2 — engine_d_decider "
          f"--live --filter {filter} --date {resolved_date}")

    engine_cmd = [
        sys.executable, "-m", "engines.refill.engine_d_decider",
        "--live",
        "--filter", filter,
        "--date", resolved_date,
    ]

    ok, engine_output = _run(engine_cmd, timeout=180)
    print(engine_output)

    if not ok:
        return JSONResponse(status_code=500, content={
            "step": "engine_d_decider",
            "error": engine_output,
            "fetch_output": fetch_output,
            "message": "❌ Engine failed — Weimi data was refreshed successfully.",
        })

    print(f"[{ts()}] ✅ Engine complete")

    return {
        "status": "ok",
        "filter": filter,
        "date": resolved_date,
        "fetch_output": fetch_output,
        "engine_output": engine_output,
        "refill_url": "https://boonz-erp.vercel.app/refill",
        "message": "✅ Data refreshed + Plan generated",
    }


@app.get("/run-engine")
def run_engine(
    filter: str = Query(default="all"),
    date: str = Query(default="tomorrow"),
):
    resolved_date = _resolve_date(date)
    ts = lambda: datetime.now().strftime("%H:%M:%S")

    print(f"\n[{ts()}] /run-engine filter={filter} date={resolved_date}")

    engine_cmd = [
        sys.executable, "-m", "engines.refill.engine_d_decider",
        "--live",
        "--filter", filter,
        "--date", resolved_date,
    ]

    ok, engine_output = _run(engine_cmd, timeout=180)
    print(engine_output)

    if not ok:
        return JSONResponse(status_code=500, content={
            "step": "engine_d_decider",
            "error": engine_output,
            "message": "❌ Engine failed.",
        })

    print(f"[{ts()}] ✅ Engine complete")

    return {
        "status": "ok",
        "filter": filter,
        "date": resolved_date,
        "engine_output": engine_output,
        "refill_url": "https://boonz-erp.vercel.app/refill",
        "message": "✅ Plan generated",
    }


if __name__ == "__main__":
    port = int(os.environ.get("BOONZ_LOCAL_PORT", "8765"))
    print(f"\n🚀 Boonz Refill Local Server")
    print(f"   http://localhost:{port}")
    print(f"   Repo: {REPO_ROOT}")
    print(f"   Press Ctrl+C to stop\n")
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
