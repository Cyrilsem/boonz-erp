// ────────────────────────────────────────────────────────────────────────────
// adjust-warehouse-line.ts
//
// FE helper that routes every per-row warehouse_inventory write through the
// canonical `adjust_warehouse_stock` RPC. Replaces the dozens of bare
// `.from("warehouse_inventory").update(...)` / `.insert(...)` call sites that
// were stamping audit rows with `authenticated_write_no_reason_set` and
// producing the "30-second undo" pattern found on 2026-05-22.
//
// Constitution Article 3: every protected-entity write goes through an RPC.
// Stax Rule S1 + S2: greppable, single literal RPC name.
//
// Usage:
//   await adjustWarehouseLine(supabase, {
//     warehouseId: row.warehouse_id,
//     line: { wh_inventory_id, boonz_product_id, ...changed fields },
//     reason: 'inline_qty_edit',
//   });
//
// What you pass in `line` must include every field you want set to a
// particular value on the row. Fields that you OMIT (i.e. the key is absent)
// will be left alone:
//   - omit `wh_location` -> location untouched
//   - omit `expiration_date` -> expiry untouched (COALESCE in RPC)
//   - omit `batch_id` -> batch untouched (COALESCE in RPC)
//   - `status` defaults to 'Active' in the RPC if omitted — pass current
//     status if you don't want it forced to Active
//   - `new_warehouse_stock` defaults to 0 — pass current qty if you only mean
//     to change metadata
//
// For pure metadata edits (location-only, status-only, expiry-only), pass
// `new_warehouse_stock` = the current qty so we don't blow it away.
// ────────────────────────────────────────────────────────────────────────────

import type { SupabaseClient } from "@supabase/supabase-js";

export interface AdjustWarehouseLine {
  /** Required when targeting a specific row (which is the common FE path). */
  wh_inventory_id?: string;
  boonz_product_id: string;
  /** Required — pass current qty if you only mean to edit metadata. */
  new_warehouse_stock: number;
  /** Defaults to 0 in the RPC if omitted. */
  new_consumer_stock?: number;
  /** Pass `null` to explicitly clear, omit the key to leave it alone. */
  expiration_date?: string | null;
  /** Pass `null` to explicitly clear, omit the key to leave it alone. */
  wh_location?: string | null;
  /** Pass `null` to leave it alone (COALESCE applies), or a new value. */
  batch_id?: string | null;
  /** Defaults to 'Active' in the RPC if omitted. */
  status?: string;
}

export interface AdjustWarehouseArgs {
  warehouseId: string;
  line: AdjustWarehouseLine;
  reason: string;
  snapshotDate?: string; // YYYY-MM-DD; defaults to CURRENT_DATE in the RPC
}

export interface AdjustWarehouseResult {
  ok: boolean;
  error?: string;
  detail?: unknown;
}

/**
 * Call the canonical adjust_warehouse_stock RPC for a single row edit.
 *
 * Why this wrapper exists rather than letting components call .rpc directly:
 *   1. One greppable call site for the audit (Stax Rule S2).
 *   2. Enforces the array-of-lines shape the RPC expects.
 *   3. Surfaces RPC errors as a typed result instead of a generic PostgrestError.
 *   4. Strips undefined keys so the RPC's "key present means set" semantics work
 *      correctly (Postgres jsonb `?` operator distinguishes missing vs null).
 */
export async function adjustWarehouseLine(
  supabase: SupabaseClient,
  args: AdjustWarehouseArgs,
): Promise<AdjustWarehouseResult> {
  if (!args.warehouseId) {
    return { ok: false, error: "warehouseId is required" };
  }
  if (!args.line.boonz_product_id) {
    return { ok: false, error: "line.boonz_product_id is required" };
  }
  if (
    args.line.new_warehouse_stock === undefined ||
    args.line.new_warehouse_stock === null ||
    Number.isNaN(args.line.new_warehouse_stock)
  ) {
    return { ok: false, error: "line.new_warehouse_stock is required" };
  }

  // Strip undefined keys so the RPC's "key present" semantics work for
  // wh_location, expiration_date, batch_id. We deliberately keep nulls — those
  // mean "explicitly clear this field".
  const cleanedLine: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(args.line)) {
    if (v !== undefined) cleanedLine[k] = v;
  }

  const { data, error } = await supabase.rpc("adjust_warehouse_stock", {
    p_warehouse_id: args.warehouseId,
    p_lines: [cleanedLine],
    p_snapshot_date: args.snapshotDate ?? null,
    p_reason: args.reason,
  });

  if (error) {
    return { ok: false, error: error.message, detail: error };
  }
  return { ok: true, detail: data };
}
