# Carve-out PRD — A.7 Hard-block direct UPDATE on warehouse_inventory

**Parent:** PRD-Phase-G v2 Section 11 (Phase 4 scope)
**Status:** Carve-out from Phase G P4. Not shipped in 2026-05-25 batch.
**Reason for carve-out:** Hard-block is a behavior-breaking change. Until every existing writer (RPC, edge function, n8n workflow, cron job) is verified to set `app.via_rpc='true'`, a row-level trigger raising on missing GUC will brick production write paths.

## Problem

Article 3 forbids direct table writes on protected entities from anything other than canonical RPCs. The constitutional layer relies on every canonical writer setting `app.via_rpc='true'` and `app.rpc_name=<name>` so that the generic audit trigger can attribute writes correctly. Yet:

- The Saturday 2026-04-25 incident traced four `warehouse_inventory` writes to a missing-GUC path (PRD-Phase-G v2 Section 4 background).
- The Phase G P4 A.8 audit (this commit batch) found that the M2M `is_m2m` flip is performed by an anonymous direct UPDATE — same vulnerability class against `refill_dispatching`, but it proves direct-UPDATE paths still exist somewhere in the stack.

A.7 closes the door with a `BEFORE UPDATE` trigger on `warehouse_inventory` that raises if `app.via_rpc IS NULL` or `app.via_rpc <> 'true'`.

## Proposed solution (sketch)

```sql
CREATE OR REPLACE FUNCTION public.refuse_direct_warehouse_inventory_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('app.via_rpc', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'direct UPDATE on warehouse_inventory forbidden (Article 3). caller must route through a canonical RPC that sets app.via_rpc=true.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_refuse_direct_wh_update
  BEFORE UPDATE ON public.warehouse_inventory
  FOR EACH ROW EXECUTE FUNCTION public.refuse_direct_warehouse_inventory_update();
```

Constitution articles satisfied: 3, 4. Note: this is a meta-trigger; it doesn't replace the audit trigger from Article 8 — it gates the path.

## Why it needs standalone staging

The trigger raises on ALL non-RPC UPDATEs. Before enabling it:

1. **Inventory of every UPDATE source.** Crawl `pg_proc` for all RPCs that touch `warehouse_inventory`. Verify each sets the GUC. Crawl n8n workflows for SQL nodes touching `warehouse_inventory`. Crawl Vercel cron / API routes for `.from('warehouse_inventory').update(...)`. Audit period: ~7 days of write traffic.
2. **Audit-only first.** Deploy as RAISE WARNING instead of RAISE EXCEPTION for one week, with the GUC check inverted (warn when `app.via_rpc IS DISTINCT FROM 'true'`). Collect warnings via Supabase logs.
3. **Flip to RAISE EXCEPTION.** Only after 7 days of zero warnings.

Doing this without the audit-only window will:

- Brick whatever path is writing the M2M flip (the F-3 finding from A.8). That path also probably writes to `warehouse_inventory` somewhere.
- Brick any forgotten n8n workflow doing nightly maintenance.
- Brick Supabase Studio manual fixes (which we sometimes use for Saturday corrections — they would need to wrap in `SELECT set_config('app.via_rpc','true',true);` first).

## Companion: warehouse_inventory.status remains untouched

Article 6 still applies — `status` is manager-only and the existing CHECK constraint enforces it. A.7 doesn't replace Article 6, it makes Article 3 enforceable globally for the whole table including non-status columns.

## Open questions for CS

1. Should the trigger also block direct INSERTs and DELETEs, or just UPDATEs? Initial reading of Article 3: all three.
2. Should the trigger have a service-role bypass? Supabase service-role bypasses RLS but does NOT bypass triggers. If the answer is no, every n8n service-role write must `SET app.via_rpc='true'` first.
3. Should the audit-only warning window be 7 or 14 days?

## Acceptance gate

- Inventory of every writer documented in `RPC_REGISTRY.md`.
- One week of RAISE WARNING with zero hits.
- Flip to RAISE EXCEPTION lands in a Monday morning window so any breakage is observed during business hours.

## Estimated ship window

Sprint after Phase G chapter closes + A.8 follow-up PRD (anonymous M2M flip root cause). A.7 should not ship before that root cause is identified and the flip path either canonicalized or removed.
