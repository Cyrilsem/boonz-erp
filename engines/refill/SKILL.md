---
name: Refill Engine
description: Run the Boonz refill brain. Fetches fresh Weimi data then
  generates a refill plan. Usage: /refill-engine [filter] [date].
  Filters: all (default), addmind (group=ADDMIND+USH), vml, vox,
  ohmydesk, wpp, office, coworking, or exact machine name like
  ADDMIND-1007-0000-W0 (single machine only).
  Date: tomorrow (default), today, YYYY-MM-DD.
trigger: /refill-engine
---

# Refill Engine

## How it works

Calls the Boonz local server at http://localhost:8765.
The server runs on your Mac with full network + .env access.
It fetches Weimi data then runs the full engine pipeline.

## STEP 0 — Always verify server is running first

GET http://localhost:8765/health

If {"status": "ok"} → proceed to Step 1.
If connection refused → tell user:

❌ Local server not running. Start it with:
cd /Users/cyrilsemaan/BOONZ\ BRAIN/boonz-erp
python -m engines.refill.local_server

Then stop. Do not proceed without the server.

## Argument parsing

Extract from user message:

filter:
"all" or nothing → all
"addmind" → addmind (venue group: ADDMIND-1007 + USH-1008)
"ADDMIND-1007-0000-W0" → ADDMIND-1007-0000-W0 (single machine)
"USH-1008-0000-W1" → USH-1008-0000-W1 (single machine)
"vml" → vml
"vox" → vox
"ohmydesk" → ohmydesk
"wpp" → wpp
"office" → office
"coworking" → coworking

date:
"today" → today
"tomorrow" or nothing → tomorrow
"2026-04-14" → 2026-04-14

## STEP 1 — Call the server

GET http://localhost:8765/run-refill?filter=<filter>&date=<date>

Wait up to 4 minutes. The fetch + engine takes 60-120 seconds normally.

On error response (status != 200):
Report: ❌ [step] failed
Show the error field
Stop.

## STEP 2 — Report output

Report exactly this format:

✅ Data refreshed + Plan generated
Filter: <filter> | Date: <date>

[paste engine_output verbatim — do not summarise]

🔗 https://boonz-erp.vercel.app/refill

## STEP 3 — Open refill page

Navigate to https://boonz-erp.vercel.app/refill

---

## Engine logic notes

### Multi-variant floor

For products with multiple boonz variants, the floor is:

- Drinks: variant_count × 3 (e.g. Popit Mix 3 flavours → 9 minimum)
- Snacks: variant_count × 1 (e.g. Chocolate Bar 7 variants → 7 minimum)
- Cap at 80% of max_stock
- Final target = MAX(velocity_target, mode_floor, variant_floor)

### Swap rate limit (updated)

First 2 swap pairs per machine per cycle: cooldown check skipped (always allowed).
From swap 3 onwards: 14-day cooldown applies as before.
Max 2 swap pairs per machine per cycle still enforced regardless.
