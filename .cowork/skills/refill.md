# Refill Engine Skill

## Trigger

/refill

## Description

Run the Boonz refill brain and open the plan review page.
Fetches the latest live data from Weimi API and Supabase,
runs all 4 engines (portfolio → quantity → swap → decider),
writes the plan to Supabase, and opens the /refill page.

## Usage

/refill
/refill office
/refill vox
/refill tomorrow office
/refill 2026-04-14 addmind
/refill ADDMIND-1007-0000-W0

## Parameters (all optional, positional)

- filter: office | coworking | entertainment | vox | wpp | addmind |
  vml | ohmydesk | <exact machine name> | all (default)
- date: tomorrow (default) | YYYY-MM-DD | today

## Steps

1. Parse the user's message to extract date and filter:
   - If message contains a date (YYYY-MM-DD or "tomorrow" or "today"):
     extract it as --date argument
   - If message contains a filter keyword (office, coworking, vox, wpp,
     addmind, vml, ohmydesk, entertainment, or a machine name):
     extract as --filter argument
   - Default: --date tomorrow --filter all

2. Fetch latest data from Weimi API (always runs first):
   cd <repo_root>
   python -m engines.refill.fetch_weimi_data

   This refreshes:
   - sales_history (today's transactions)
   - weimi_device_status (live slot stock levels)

   The engine plans off this fresh data. If this step fails,
   stop and report the error — do not run the engine on stale data.

3. Run the refill engine:
   python -m engines.refill.engine_d_decider --live \
    --date <date> \
    --filter <filter>

4. On success, open this URL in the browser:
   https://boonz-erp.vercel.app/refill

5. Respond with a summary:
   ✅ Data refreshed + Refill plan generated
   📅 Date: <plan_date>
   🏭 Filter: <filter>
   📋 Lines: <N> (<refill_count> refills + <swap_count> swaps)
   📦 Units: <N>
   🔗 https://boonz-erp.vercel.app/refill

## Error handling

If fetch_weimi_data fails:
❌ Data fetch failed — engine not run (would plan off stale data).
Check Weimi API credentials in .env and network connectivity.
Common causes:

- .env missing WEIMI_APP_ID or WEIMI_SECRET_KEY
- Network error reaching micron.weimi24.com

If the engine exits with non-zero:
❌ Engine failed — data was refreshed successfully.
Check the output above for details.
Common causes:

- .env missing SUPABASE_URL or SUPABASE_SERVICE_KEY
- Python dependencies not installed (pip install -r requirements.txt)
- Network error fetching fleet state from Supabase
