"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

// ─── Types ────────────────────────────────────────────────────────────────────

export type EditRole =
  | "driver"
  | "warehouse_manager"
  | "operator_admin"
  | "superadmin"
  | "manager";
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
