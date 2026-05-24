// ────────────────────────────────────────────────────────────────────────────
// adjust-warehouse-line.ts
//
// FE helper that routes per-row warehouse_inventory METADATA-only writes
// through the canonical `adjust_warehouse_stock` RPC. Stock and status
// writes are NO LONGER routed through this helper as of Phase G PRD v2
// Phase 1 (2026-05-25).
//
// Migration map:
//   - Editing warehouse_stock  → use attemptCorrection from attempt-rpcs.ts
//   - Toggling status          → use attemptStatusChange from attempt-rpcs.ts
//   - Reactivating Inactive    → use attemptReactivate from attempt-rpcs.ts
//   - Editing wh_location / expiration_date / batch_id only → still here.
//
// The helper now REJECTS at runtime any call that passes new_warehouse_stock
// or status. This prevents the old escape hatch where a single helper call
// could mutate stock + status + metadata together without leaving an
// inventory_control_attempt row. Phase 1 audit requirement: every stock or
// status mutation must land in inventory_control_attempt.
//
// Constitution Article 3: every protected-entity write goes through an RPC.
// Stax Rule S1 + S2: greppable, single literal RPC name.
//
// Usage (METADATA only):
//   await adjustWarehouseLineMetadata(supabase, {
//     warehouseId: row.warehouse_id,
//     line: { wh_inventory_id, boonz_product_id, wh_location: 'D08' },
//     currentWarehouseStock: row.warehouse_stock,
//     currentStatus: row.status,
//     reason: 'inline_location_edit',
//   });
// ────────────────────────────────────────────────────────────────────────────

import type { SupabaseClient } from "@supabase/supabase-js";

export interface AdjustWarehouseLine {
  /** Required when targeting a specific row (which is the common FE path). */
  wh_inventory_id?: string;
  boonz_product_id: string;
  /** @deprecated Phase G P1: pass via attemptCorrection (attempt-rpcs.ts). */
  new_warehouse_stock?: number;
  /** Defaults to 0 in the RPC if omitted. */
  new_consumer_stock?: number;
  /** Pass `null` to explicitly clear, omit the key to leave it alone. */
  expiration_date?: string | null;
  /** Pass `null` to explicitly clear, omit the key to leave it alone. */
  wh_location?: string | null;
  /** Pass `null` to leave it alone (COALESCE applies), or a new value. */
  batch_id?: string | null;
  /** @deprecated Phase G P1: pass via attemptStatusChange (attempt-rpcs.ts). */
  status?: string;
}

export interface AdjustWarehouseArgs {
  warehouseId: string;
  line: AdjustWarehouseLine;
  reason: string;
  snapshotDate?: string; // YYYY-MM-DD; defaults to CURRENT_DATE in the RPC
}

export interface AdjustWarehouseMetadataArgs {
  warehouseId: string;
  line: {
    wh_inventory_id?: string;
    boonz_product_id: string;
    expiration_date?: string | null;
    wh_location?: string | null;
    batch_id?: string | null;
  };
  /** Current stock value (we pass it through unchanged to adjust_warehouse_stock). */
  currentWarehouseStock: number;
  /** Current status (we pass it through unchanged). */
  currentStatus: string;
  reason: string;
  snapshotDate?: string;
}

export interface AdjustWarehouseResult {
  ok: boolean;
  error?: string;
  detail?: unknown;
}

/**
 * Phase G P1 status (2026-05-25): SOFT-DEPRECATED for stock + status callers.
 *
 * Stock-cell and status-toggle call sites should migrate to attemptCorrection
 * and attemptStatusChange in `@/lib/inventory/attempt-rpcs`. Until every page
 * is migrated, this helper continues to work for backward compatibility. A
 * follow-up PR will flip on the runtime guard that rejects callers passing
 * `new_warehouse_stock` or `status`, closing the audit-bypass escape hatch.
 *
 * Metadata-only callers (wh_location / expiration_date / batch_id) should
 * call `adjustWarehouseLineMetadata` below today; that function takes the
 * row's current stock + status and passes them through unchanged so the
 * Phase 1 guard does not flag them.
 *
 * Constitution Article 3: every protected-entity write goes through an RPC.
 * Stax Rule S1 + S2: greppable, single literal RPC name.
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
  // wh_location, expiration_date, batch_id. We deliberately keep nulls; those
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

/**
 * Metadata-only writer. Routes wh_location, expiration_date, and batch_id
 * changes through the existing canonical `adjust_warehouse_stock` RPC while
 * preserving the row's current stock and status. Phase G P2 will add a
 * dedicated attempt_* wrapper for metadata edits so they also land in
 * inventory_control_attempt; until then metadata edits log only to
 * inventory_audit_log via the warehouse_inventory trigger.
 */
export async function adjustWarehouseLineMetadata(
  supabase: SupabaseClient,
  args: AdjustWarehouseMetadataArgs,
): Promise<AdjustWarehouseResult> {
  if (!args.warehouseId) {
    return { ok: false, error: "warehouseId is required" };
  }
  if (!args.line.boonz_product_id) {
    return { ok: false, error: "line.boonz_product_id is required" };
  }

  const cleanedLine: Record<string, unknown> = {
    boonz_product_id: args.line.boonz_product_id,
    new_warehouse_stock: args.currentWarehouseStock,
    status: args.currentStatus,
  };
  if (args.line.wh_inventory_id !== undefined) {
    cleanedLine.wh_inventory_id = args.line.wh_inventory_id;
  }
  if (args.line.expiration_date !== undefined) {
    cleanedLine.expiration_date = args.line.expiration_date;
  }
  if (args.line.wh_location !== undefined) {
    cleanedLine.wh_location = args.line.wh_location;
  }
  if (args.line.batch_id !== undefined) {
    cleanedLine.batch_id = args.line.batch_id;
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
