"""
fetch_weimi_data.py
Fetch live data from Weimi API and write to Supabase.
Run before the refill engine to ensure plans are based on fresh data.

Two parallel operations:
  1. today-order-page  → upsert_daily_sales()      → sales_history
  2. device-info       → weimi_device_status table  → v_live_shelf_stock

Usage:
  python -m engines.refill.fetch_weimi_data
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import string
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import requests
from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()

# ── Constants ───────────────────────────────────────────────────────────────

BASE_URL = "https://micron.weimi24.com/v8/third-center-web"
SALES_ENDPOINT = "/ext/today-order-page"
DEVICE_ENDPOINT = "/ext/device-info"
PAGE_SIZE = 100
SALES_BATCH_SIZE = 50


# ── Auth ────────────────────────────────────────────────────────────────────

def _sign(params: dict, app_id: str, secret_key: str) -> dict:
    """
    Build Weimi HMAC-SHA1 signed headers.
    Signature string: secretKey={s},nonce={n},timestamp={t},appId={a},paramJson={p}
    IMPORTANT: params must be exactly the POST body — no extra fields.
    """
    nonce = ''.join(random.choices(string.ascii_lowercase + string.digits, k=16))
    ts = str(int(time.time() * 1000))
    param_json = json.dumps(params, separators=(',', ':'))
    raw = f"secretKey={secret_key},nonce={nonce},timestamp={ts},appId={app_id},paramJson={param_json}"
    sig = hashlib.sha1(raw.encode()).hexdigest()
    return {
        "Client-Type": "EXTERNAL",
        "SIGN": sig,
        "TIMESTAMP": ts,
        "NONCE": nonce,
        "APP_ID": app_id,
        "Content-Type": "application/json",
    }


def _sign_get(app_id: str, secret_key: str) -> dict:
    """
    Build signed headers for GET requests (empty param dict — no body).
    """
    return _sign({}, app_id, secret_key)


# ── Env validation ──────────────────────────────────────────────────────────

def _get_env() -> tuple[str, str, Client]:
    """
    Validate required .env keys. Raises SystemExit with a clear message
    listing every missing key rather than crashing with a KeyError.
    """
    missing: list[str] = []

    app_id = os.environ.get("WEIMI_APP_ID", "")
    secret_key = os.environ.get("WEIMI_SECRET_KEY") or os.environ.get("WEIMI_SECRET", "")
    supabase_url = os.environ.get("SUPABASE_URL", "")
    supabase_key = (
        os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        or os.environ.get("SUPABASE_SERVICE_KEY", "")
    )

    if not app_id:
        missing.append("WEIMI_APP_ID")
    if not secret_key:
        missing.append("WEIMI_SECRET_KEY")
    if not supabase_url:
        missing.append("SUPABASE_URL")
    if not supabase_key:
        missing.append("SUPABASE_SERVICE_KEY (or SUPABASE_SERVICE_ROLE_KEY)")

    if missing:
        print(f"Missing .env keys: {', '.join(missing)}")
        raise SystemExit(1)

    client = create_client(supabase_url, supabase_key)
    return app_id, secret_key, client


# ── Operation 1 — Today's sales ─────────────────────────────────────────────

def _transform_order_item(item: dict) -> dict:
    """
    Transform a Weimi order line into the shape upsert_daily_sales() expects.

    Weimi field → DB field mapping:
      txnSn + itemRank  → internal_txn_sn  (constructed: "{txnSn}_{itemRank}")
      machineName       → machine_name
      goodsName         → product_name
      salePrice         → unit_price       (Weimi: fils/cents → ÷100 → AED)
      qty               → qty
      payMoney          → paid_amount      (fils → AED)
      totalMoney        → total_amount     (fils → AED, optional)
      deliveryStatus    → delivery_status
      txnTime           → time
      itemRank          → item_rank        (also used as goods_slot)
    """
    txn_sn = str(item.get("txnSn") or "")
    item_rank = str(item.get("itemRank") or "1")
    internal_txn_sn = f"{txn_sn}_{item_rank}" if txn_sn else None

    # Prices from Weimi are in smallest unit (fils). Divide by 100 for AED.
    def _to_aed(val: object) -> float | None:
        if val is None:
            return None
        try:
            return round(float(val) / 100, 2)
        except (TypeError, ValueError):
            return None

    return {
        "internal_txn_sn": internal_txn_sn,
        "machine_name":     item.get("machineName") or "",
        "product_name":     item.get("goodsName") or "",
        "unit_price":       _to_aed(item.get("salePrice")),
        "qty":              item.get("qty"),
        "paid_amount":      _to_aed(item.get("payMoney")),
        "total_amount":     _to_aed(item.get("totalMoney")),
        "delivery_status":  item.get("deliveryStatus") or "",
        "time":             item.get("txnTime") or "",
        "item_rank":        item_rank,
    }


def _fetch_today_sales(app_id: str, secret_key: str, client: Client) -> dict:
    """
    Paginate Weimi today-order-page, transform, upsert in batches of 50.
    Returns summary dict: {transactions, upserted, skipped, pages}.
    """
    all_items: list[dict] = []
    page = 1

    while True:
        params = {"current": page, "size": PAGE_SIZE}
        headers = _sign(params, app_id, secret_key)
        resp = requests.post(
            BASE_URL + SALES_ENDPOINT,
            headers=headers,
            data=json.dumps(params, separators=(',', ':')),
            timeout=30,
        )
        resp.raise_for_status()
        body = resp.json()

        # Weimi wraps results in data.records or data directly
        data = body.get("data") or {}
        records: list[dict] = (
            data.get("records")
            or data.get("list")
            or (data if isinstance(data, list) else [])
        )

        if not records:
            break

        all_items.extend(records)

        # Stop paginating when fewer than a full page returned
        if len(records) < PAGE_SIZE:
            break

        page += 1

    if not all_items:
        return {"transactions": 0, "upserted": 0, "skipped": 0, "pages": page}

    transformed = [_transform_order_item(item) for item in all_items]

    # Filter out items with no internal_txn_sn (can't upsert without PK)
    valid = [t for t in transformed if t.get("internal_txn_sn")]

    total_upserted = 0
    total_skipped = 0

    # Batch upsert
    for i in range(0, len(valid), SALES_BATCH_SIZE):
        batch = valid[i : i + SALES_BATCH_SIZE]
        result = client.rpc("upsert_daily_sales", {"p_items": json.dumps(batch)}).execute()
        if result.data:
            res = result.data if isinstance(result.data, dict) else {}
            total_upserted += res.get("upserted", len(batch))
            total_skipped += res.get("skipped", 0)
        else:
            total_upserted += len(batch)

    return {
        "transactions": len(valid),
        "upserted": total_upserted,
        "skipped": total_skipped,
        "pages": page,
    }


# ── Operation 2 — Live slot snapshot ────────────────────────────────────────

def _calc_total_stock(door_statuses: list) -> int:
    """Sum currStock across all cabinets → layers → aisles."""
    total = 0
    for cabinet in door_statuses or []:
        for layer in (cabinet.get("layers") or []):
            for aisle in (layer.get("aisles") or []):
                try:
                    total += int(aisle.get("currStock") or 0)
                except (TypeError, ValueError):
                    pass
    return total


def _fetch_device_snapshot(app_id: str, secret_key: str, client: Client) -> dict:
    """
    Fetch all devices from Weimi /device-info (GET), upsert to weimi_device_status.
    Resolves machine_id by matching device_name against machines.official_name.
    Returns summary dict: {slots, devices, upserted}.
    """
    headers = _sign_get(app_id, secret_key)
    resp = requests.get(
        BASE_URL + DEVICE_ENDPOINT,
        headers=headers,
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()

    # Device list can be at data.list, data.records, or data directly
    data = body.get("data") or {}
    devices: list[dict] = (
        data.get("list")
        or data.get("records")
        or (data if isinstance(data, list) else [])
    )

    if not devices:
        return {"slots": 0, "devices": 0, "upserted": 0}

    # Resolve machine_id: fetch all machines once, build name→id map
    machines_resp = (
        client.table("machines")
        .select("machine_id, official_name")
        .limit(10000)
        .execute()
    )
    name_to_id: dict[str, str] = {
        r["official_name"]: r["machine_id"]
        for r in (machines_resp.data or [])
    }

    now_ts = datetime.now(timezone.utc).isoformat()
    today_date = datetime.now(timezone.utc).date().isoformat()

    rows: list[dict] = []
    total_slots = 0

    for dev in devices:
        # Weimi field names (camelCase) → DB column names (snake_case)
        device_id = str(dev.get("deviceId") or dev.get("deviceCode") or "")
        device_code = str(dev.get("deviceCode") or "")
        device_name = str(dev.get("deviceName") or "")

        # door_statuses: Weimi may call this doorStatuses, doorStatus, or doors
        door_statuses = (
            dev.get("doorStatuses")
            or dev.get("doorStatus")
            or dev.get("doors")
            or []
        )
        if isinstance(door_statuses, str):
            try:
                door_statuses = json.loads(door_statuses)
            except (json.JSONDecodeError, ValueError):
                door_statuses = []

        # Prefer explicit weimi_device_id (hex string); fall back to deviceCode
        weimi_device_id = str(
            dev.get("weimi_device_id")
            or dev.get("deviceId")
            or device_code
        )

        curr_stock = _calc_total_stock(door_statuses)
        total_slots += curr_stock

        cabinet_count = len(door_statuses) if isinstance(door_statuses, list) else 1
        machine_id = name_to_id.get(device_name)

        rows.append({
            "weimi_device_id": weimi_device_id,
            "device_code":     device_code,
            "device_name":     device_name,
            "machine_id":      machine_id,
            "is_covered":      bool(dev.get("isCovered", False)),
            "is_running":      bool(dev.get("isRunning", False)),
            "total_curr_stock": curr_stock,
            "cabinet_count":   cabinet_count,
            "door_statuses":   door_statuses,
            "snapshot_at":     now_ts,
            "snapshot_date":   today_date,
        })

    if not rows:
        return {"slots": 0, "devices": 0, "upserted": 0}

    # Upsert — conflict on (weimi_device_id, snapshot_date)
    client.table("weimi_device_status").upsert(
        rows,
        on_conflict="weimi_device_id,snapshot_date",
    ).execute()

    return {
        "slots": total_slots,
        "devices": len(rows),
        "upserted": len(rows),
    }


# ── Main ────────────────────────────────────────────────────────────────────

def main() -> None:
    app_id, secret_key, client = _get_env()

    started_at = datetime.now(timezone.utc)
    print(f"\n=== BOONZ DATA FETCH — {started_at.strftime('%Y-%m-%d %H:%M:%S')} ===")

    results: dict[str, object] = {}
    errors: dict[str, str] = {}

    def run_sales() -> dict:
        print("Fetching today's sales from Weimi...")
        return _fetch_today_sales(app_id, secret_key, client)

    def run_devices() -> dict:
        print("Fetching live slot snapshot from Weimi...")
        return _fetch_device_snapshot(app_id, secret_key, client)

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = {
            executor.submit(run_sales): "sales",
            executor.submit(run_devices): "devices",
        }
        for future in as_completed(futures):
            name = futures[future]
            try:
                results[name] = future.result()
            except Exception as exc:
                errors[name] = str(exc)

    # Print results
    if "sales" in results:
        s = results["sales"]
        print(
            f"✓ {s['transactions']} transactions "
            f"({s['pages']} page{'s' if s['pages'] != 1 else ''})"
        )
        print(
            f"✓ Upserted to sales_history "
            f"({s['upserted']} new, {s['skipped']} skipped)"
        )
    elif "sales" in errors:
        print(f"✗ Sales fetch failed: {errors['sales']}")

    if "devices" in results:
        d = results["devices"]
        print(f"✓ {d['devices']} devices, {d['slots']} total slot-units")
        print(f"✓ Upserted to weimi_device_status ({d['upserted']} rows)")
    elif "devices" in errors:
        print(f"✗ Device fetch failed: {errors['devices']}")

    elapsed = (datetime.now(timezone.utc) - started_at).total_seconds()
    print(f"=== FETCH COMPLETE — {elapsed:.1f}s ===\n")

    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
