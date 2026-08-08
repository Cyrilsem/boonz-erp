"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

// ─── Types ────────────────────────────────────────────────────────────────────

export type EditRole =
  "driver" | "warehouse_manager" | "operator_admin" | "superadmin" | "manager";
// SourceKind: only "wh" (Warehouse) and "m2m" (From another machine) are user-pickable.
// "truck_transfer" and "unknown" remain DB-valid for legacy rows but are no longer exposed in the FE.
export type SourceKind = "wh" | "m2m";

interface ActionResult<T = unknown> {
  ok: boolean;
  data?: T;
  error?: string;
}

// ─── 1) edit_dispatch_qty ─────────────────────────────────────────────────────

export async function editDispatchQty(input: {
  dispatchId: string;
  newQty: number;
  editRole: EditRole;
  reason?: string;
  revalidate?: string;
}): Promise<ActionResult> {
  if (input.newQty < 0) return { ok: false, error: "Quantity must be ≥ 0" };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("edit_dispatch_qty", {
    p_dispatch_id: input.dispatchId,
    p_new_qty: input.newQty,
    p_edit_role: input.editRole,
    p_reason: input.reason ?? null,
    p_conductor_session: null,
  });
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data };
}

// ─── 1b) edit_transfer_qty (PRD-049 Phase C) ──────────────────────────────────
// Atomic both-leg qty edit for an M2M transfer pair. Use this instead of
// editDispatchQty when the row is an M2M transfer (sourceKind 'm2m'); the single-leg
// editDispatchQty would desync the Remove+Add New legs.
export async function editTransferQty(input: {
  dispatchId: string;
  newQty: number;
  editRole: EditRole;
  reason?: string;
  revalidate?: string;
}): Promise<ActionResult> {
  if (input.newQty <= 0)
    return { ok: false, error: "Transfer quantity must be > 0" };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("edit_transfer_qty", {
    p_dispatch_id: input.dispatchId,
    p_new_qty: input.newQty,
    p_edit_role: input.editRole,
    p_reason: input.reason ?? null,
  });
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data };
}

// ─── 2) edit_dispatch_shelf ───────────────────────────────────────────────────

export async function editDispatchShelf(input: {
  dispatchId: string;
  newShelfCode: string;
  editRole: EditRole;
  reason?: string;
  revalidate?: string;
}): Promise<ActionResult> {
  if (!input.newShelfCode.trim())
    return { ok: false, error: "Shelf code required" };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("edit_dispatch_shelf", {
    p_dispatch_id: input.dispatchId,
    p_new_shelf_code: input.newShelfCode.trim().toUpperCase(),
    p_edit_role: input.editRole,
    p_reason: input.reason ?? null,
    p_conductor_session: null,
  });
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data };
}

// ─── 3) edit_dispatch_product ─────────────────────────────────────────────────

export async function editDispatchProduct(input: {
  dispatchId: string;
  newBoonzProductId: string;
  editRole: EditRole;
  reason?: string;
  revalidate?: string;
}): Promise<ActionResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("edit_dispatch_product", {
    p_dispatch_id: input.dispatchId,
    p_new_boonz_product_id: input.newBoonzProductId,
    p_edit_role: input.editRole,
    p_reason: input.reason ?? null,
    p_conductor_session: null,
  });
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data };
}

// ─── 3b) driver_substitute_dispatch_line (PRD-112) ────────────────────────────
// The driver standing at the machine swapping one product for another. Unlike
// editDispatchProduct this works on a packed + picked_up line (that is the normal
// case), records what was ACTUALLY filled, and raises a day-close note for CS.
// It never blocks on business grounds: a missing batch or an unmapped product
// comes back ok with needs_review set, not as an error.
export type SubstitutionSourceTag = "venue" | "wh" | "spot";

export interface SubstitutionResult {
  ok: boolean;
  dispatch_id: string;
  machine_name: string | null;
  shelf_code: string | null;
  after: { needs_review?: boolean; review_reason?: string | null };
  day_close_event_id: string;
  comment: string;
}

export async function driverSubstituteDispatchLine(input: {
  dispatchId: string;
  newBoonzProductId: string;
  filledQty: number;
  reason: string;
  actorId?: string;
  sourceTag?: SubstitutionSourceTag;
  revalidate?: string;
}): Promise<ActionResult<SubstitutionResult>> {
  if (!input.newBoonzProductId)
    return { ok: false, error: "Pick the product you actually filled" };
  // Mirrors the RPC's own rule: a zero fill is the not-filled flow, not a
  // substitution. Caught here so the driver gets the sentence, not a DB error.
  if (!Number.isFinite(input.filledQty) || input.filledQty <= 0)
    return {
      ok: false,
      error: "Quantity must be > 0 — use “Not filled” if nothing went in",
    };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc(
    "driver_substitute_dispatch_line",
    {
      p_dispatch_id: input.dispatchId,
      p_new_boonz_product_id: input.newBoonzProductId,
      p_filled_qty: input.filledQty,
      p_reason: input.reason || null,
      p_actor: input.actorId ?? null,
      p_source_tag: input.sourceTag ?? null,
    },
  );
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data: data as SubstitutionResult };
}

// Products offered in the Change-product picker. Only products with an Active
// mapping the machine can actually resolve are listed, and venue_team-supplied
// ones sort first: on a VOX machine those are the flavors the venue itself
// stocks, which is what the driver is most often reaching for.
export async function listSubstituteProducts(machineId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("product_mapping")
    .select(
      "boonz_product_id, source_of_supply, machine_id, is_global_default, boonz_products(boonz_product_name)",
    )
    .eq("status", "Active")
    .or(`machine_id.eq.${machineId},machine_id.is.null`)
    .limit(10000);
  if (error) return { ok: false as const, data: [], error: error.message };

  type Row = {
    boonz_product_id: string | null;
    source_of_supply: string | null;
    machine_id: string | null;
    boonz_products: { boonz_product_name: string | null } | null;
  };
  const byId = new Map<
    string,
    { product_id: string; name: string; venue: boolean; machineScoped: boolean }
  >();
  for (const r of (data ?? []) as unknown as Row[]) {
    const id = r.boonz_product_id;
    const name = r.boonz_products?.boonz_product_name;
    if (!id || !name) continue;
    const prev = byId.get(id);
    const venue = r.source_of_supply === "venue_team";
    const machineScoped = r.machine_id === machineId;
    // A product mapped more than once keeps the strongest signal it has.
    byId.set(id, {
      product_id: id,
      name,
      venue: venue || (prev?.venue ?? false),
      machineScoped: machineScoped || (prev?.machineScoped ?? false),
    });
  }
  const rows = [...byId.values()].sort(
    (a, b) =>
      Number(b.venue) - Number(a.venue) ||
      Number(b.machineScoped) - Number(a.machineScoped) ||
      a.name.localeCompare(b.name),
  );
  return { ok: true as const, data: rows, error: undefined };
}

// ─── 4) add_dispatch_row ──────────────────────────────────────────────────────

export async function addDispatchRow(input: {
  machineId: string;
  shelfCode: string;
  boonzProductId: string;
  quantity: number;
  action: "Refill" | "Add New" | "Remove";
  dispatchDate: string; // ISO date
  sourceKind: SourceKind;
  sourceWarehouseId?: string;
  sourceMachineId?: string;
  editRole: EditRole;
  reason?: string;
  revalidate?: string;
}): Promise<ActionResult> {
  if (input.quantity <= 0) return { ok: false, error: "Quantity must be > 0" };
  if (input.sourceKind === "wh" && !input.sourceWarehouseId)
    return { ok: false, error: "WH source requires a warehouse" };
  if (input.sourceKind === "m2m" && !input.sourceMachineId)
    return { ok: false, error: "M2M source requires a source machine" };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("add_dispatch_row", {
    p_machine_id: input.machineId,
    p_shelf_code: input.shelfCode.trim().toUpperCase(),
    p_boonz_product_id: input.boonzProductId,
    p_quantity: input.quantity,
    p_action: input.action,
    p_dispatch_date: input.dispatchDate,
    p_source_kind: input.sourceKind,
    p_source_warehouse_id: input.sourceWarehouseId ?? null,
    p_source_machine_id: input.sourceMachineId ?? null,
    p_edit_role: input.editRole,
    p_reason: input.reason ?? null,
    p_conductor_session: null,
  });
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data };
}

// ─── 4b) driver_add_flagged_row (PRD-053 Phase C) ─────────────────────────────
// A driver adding a product beyond the plan on the packing page. Composes the
// canonical add_dispatch_row (via the DEFINER wrapper) then flags the row for
// Head Office review (needs_review / review_reason='driver_addition'). Never
// blocks; auto-populates /admin/driver-additions. edit_role is forced to 'driver'.
export async function driverAddFlaggedRow(input: {
  machineId: string;
  shelfCode: string;
  boonzProductId: string;
  quantity: number;
  action: "Refill" | "Add New" | "Remove";
  dispatchDate: string;
  sourceKind: SourceKind;
  sourceWarehouseId?: string;
  sourceMachineId?: string;
  reason?: string;
  revalidate?: string;
}): Promise<ActionResult> {
  if (input.quantity <= 0) return { ok: false, error: "Quantity must be > 0" };
  if (input.sourceKind === "wh" && !input.sourceWarehouseId)
    return { ok: false, error: "WH source requires a warehouse" };
  if (input.sourceKind === "m2m" && !input.sourceMachineId)
    return { ok: false, error: "M2M source requires a source machine" };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("driver_add_flagged_row", {
    p_machine_id: input.machineId,
    p_shelf_code: input.shelfCode.trim().toUpperCase(),
    p_boonz_product_id: input.boonzProductId,
    p_quantity: input.quantity,
    p_action: input.action,
    p_dispatch_date: input.dispatchDate,
    p_source_kind: input.sourceKind,
    p_source_warehouse_id: input.sourceWarehouseId ?? null,
    p_source_machine_id: input.sourceMachineId ?? null,
    p_edit_role: "driver",
    p_reason: input.reason ?? null,
    p_conductor_session: null,
  });
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data };
}

// ─── 5) remove_dispatch_row ───────────────────────────────────────────────────

export async function removeDispatchRow(input: {
  dispatchId: string;
  editRole: EditRole;
  reason?: string;
  revalidate?: string;
}): Promise<ActionResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("remove_dispatch_row", {
    p_dispatch_id: input.dispatchId,
    p_edit_role: input.editRole,
    p_reason: input.reason ?? null,
    p_conductor_session: null,
  });
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data };
}

// ─── 6) set_dispatch_source ───────────────────────────────────────────────────

export async function setDispatchSource(input: {
  dispatchId: string;
  sourceKind: SourceKind;
  sourceWarehouseId?: string;
  sourceMachineId?: string;
  editRole: EditRole;
  reason?: string;
  revalidate?: string;
}): Promise<ActionResult> {
  if (input.sourceKind === "wh" && !input.sourceWarehouseId)
    return { ok: false, error: "WH source requires a warehouse" };
  if (input.sourceKind === "m2m" && !input.sourceMachineId)
    return { ok: false, error: "M2M source requires a source machine" };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_dispatch_source", {
    p_dispatch_id: input.dispatchId,
    p_source_kind: input.sourceKind,
    p_source_warehouse_id: input.sourceWarehouseId ?? null,
    p_source_machine_id: input.sourceMachineId ?? null,
    p_edit_role: input.editRole,
    p_reason: input.reason ?? null,
    p_conductor_session: null,
  });
  if (error) return { ok: false, error: error.message };
  if (input.revalidate) revalidatePath(input.revalidate);
  return { ok: true, data };
}

// ─── Helper: list warehouses + machines for source picker ────────────────────

export async function listWarehouses() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("warehouses")
    .select("warehouse_id, name, display_name")
    .eq("is_active", true)
    .order("name");
  return { ok: !error, data: data ?? [], error: error?.message };
}

export async function listActiveMachines() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("machines")
    .select("machine_id, official_name, location_type, venue_group")
    .eq("status", "Active")
    .order("official_name");
  return { ok: !error, data: data ?? [], error: error?.message };
}

// ─── Helper: list boonz_products for product substitution ────────────────────

export async function searchBoonzProducts(query: string) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("boonz_products")
    .select("product_id, boonz_product_name")
    .ilike("boonz_product_name", `%${query}%`)
    .order("boonz_product_name")
    .limit(20);
  return { ok: !error, data: data ?? [], error: error?.message };
}
