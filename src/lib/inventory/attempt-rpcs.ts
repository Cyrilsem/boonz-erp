// Phase G PRD v2 Phase 1 FE wiring.
//
// Thin client-side wrappers around the SECURITY DEFINER session and attempt
// RPCs (migration phaseG_p1_c3_inventory_control_rpcs). Every WH inventory
// mutation surface in the FE goes through these wrappers, so the audit trail
// in inventory_control_attempt captures both success and failure with a
// stable correlation id.
//
// The backend wrappers themselves never raise; they catch the inner canonical
// RPC's exception in PL/pgSQL and return a structured response. We still
// wrap the supabase.rpc call in try/catch to capture the rare transport-level
// failure (network drop, edge function down, JWT expired) and record it as
// result='network_error' via a direct INSERT into inventory_control_attempt
// (permitted by the ica_insert RLS policy for staff roles).

import type { SupabaseClient } from "@supabase/supabase-js";

export type AttemptResult =
  | "success"
  | "blocked_rls"
  | "blocked_trigger"
  | "rpc_error"
  | "validation_error"
  | "network_error"
  | "other";

export interface WrapperResponse {
  attempt_id: string | null;
  result: AttemptResult;
  rpc_response: Record<string, unknown> | null;
  error: string | null;
  rpc_called?: string | null;
}

export function correlationId(): string {
  if (
    typeof crypto !== "undefined" &&
    typeof crypto.randomUUID === "function"
  ) {
    return crypto.randomUUID();
  }
  // Fallback for older environments: timestamp + random suffix.
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`;
}

export interface StartSessionArgs {
  scopeWarehouseId: string;
  scopeProductIds?: string[] | null;
  sessionSlug?: string | null;
}

export interface SessionHandle {
  session_id: string;
  session_slug: string | null;
  scope_warehouse_id: string;
  status: "open";
}

export async function startInventorySession(
  supabase: SupabaseClient,
  args: StartSessionArgs,
): Promise<SessionHandle> {
  const { data, error } = await supabase.rpc("start_inventory_session", {
    p_scope_warehouse_id: args.scopeWarehouseId,
    p_scope_product_ids: args.scopeProductIds ?? null,
    p_session_slug: args.sessionSlug ?? null,
  });
  if (error)
    throw new Error(`start_inventory_session failed: ${error.message}`);
  const handle = data as SessionHandle;
  if (!handle?.session_id) {
    throw new Error("start_inventory_session: no session_id in response");
  }
  return handle;
}

export interface CloseSessionResponse {
  session_id: string;
  status: "closed";
  summary: Record<string, unknown>;
}

export async function closeInventorySession(
  supabase: SupabaseClient,
  sessionId: string,
  summary?: Record<string, unknown>,
): Promise<CloseSessionResponse> {
  const { data, error } = await supabase.rpc("close_inventory_session", {
    p_session_id: sessionId,
    p_summary: summary ?? null,
  });
  if (error)
    throw new Error(`close_inventory_session failed: ${error.message}`);
  return data as CloseSessionResponse;
}

export interface AttemptCorrectionArgs {
  sessionId: string;
  whInventoryId: string;
  newWarehouseStock: number;
  reason: string;
  correlationId: string;
}

export async function attemptCorrection(
  supabase: SupabaseClient,
  args: AttemptCorrectionArgs,
): Promise<WrapperResponse> {
  try {
    const { data, error } = await supabase.rpc("attempt_inventory_correction", {
      p_session_id: args.sessionId,
      p_wh_inventory_id: args.whInventoryId,
      p_new_warehouse_stock: args.newWarehouseStock,
      p_reason: args.reason,
      p_client_correlation_id: args.correlationId,
    });
    if (error) {
      const wrapped = await recordClientFailure(supabase, {
        sessionId: args.sessionId,
        whInventoryId: args.whInventoryId,
        fieldChanged: "warehouse_stock",
        rpcCalled: "attempt_inventory_correction",
        reason: args.reason,
        correlationId: args.correlationId,
        errorMessage: error.message,
      });
      return {
        attempt_id: wrapped.attempt_id,
        result: "network_error",
        rpc_response: null,
        error: error.message,
        rpc_called: "attempt_inventory_correction",
      };
    }
    return data as WrapperResponse;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const wrapped = await recordClientFailure(supabase, {
      sessionId: args.sessionId,
      whInventoryId: args.whInventoryId,
      fieldChanged: "warehouse_stock",
      rpcCalled: "attempt_inventory_correction",
      reason: args.reason,
      correlationId: args.correlationId,
      errorMessage: msg,
    });
    return {
      attempt_id: wrapped.attempt_id,
      result: "network_error",
      rpc_response: null,
      error: msg,
      rpc_called: "attempt_inventory_correction",
    };
  }
}

export interface AttemptStatusChangeArgs {
  sessionId: string;
  whInventoryId: string;
  newStatus: "Active" | "Inactive";
  reason: string;
  correlationId: string;
  newWarehouseStock?: number;
}

export async function attemptStatusChange(
  supabase: SupabaseClient,
  args: AttemptStatusChangeArgs,
): Promise<WrapperResponse> {
  try {
    const { data, error } = await supabase.rpc("attempt_status_change", {
      p_session_id: args.sessionId,
      p_wh_inventory_id: args.whInventoryId,
      p_new_status: args.newStatus,
      p_reason: args.reason,
      p_client_correlation_id: args.correlationId,
      p_new_warehouse_stock: args.newWarehouseStock ?? null,
    });
    if (error) {
      const wrapped = await recordClientFailure(supabase, {
        sessionId: args.sessionId,
        whInventoryId: args.whInventoryId,
        fieldChanged: "status",
        rpcCalled: "attempt_status_change",
        reason: args.reason,
        correlationId: args.correlationId,
        errorMessage: error.message,
      });
      return {
        attempt_id: wrapped.attempt_id,
        result: "network_error",
        rpc_response: null,
        error: error.message,
        rpc_called: "attempt_status_change",
      };
    }
    return data as WrapperResponse;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const wrapped = await recordClientFailure(supabase, {
      sessionId: args.sessionId,
      whInventoryId: args.whInventoryId,
      fieldChanged: "status",
      rpcCalled: "attempt_status_change",
      reason: args.reason,
      correlationId: args.correlationId,
      errorMessage: msg,
    });
    return {
      attempt_id: wrapped.attempt_id,
      result: "network_error",
      rpc_response: null,
      error: msg,
      rpc_called: "attempt_status_change",
    };
  }
}

export interface AttemptReactivateArgs {
  sessionId: string;
  whInventoryId: string;
  newWarehouseStock: number;
  reason: string;
  correlationId: string;
  sourceDoc?: string | null;
  newExpirationDate?: string | null;
  newWhLocation?: string | null;
}

export async function attemptReactivate(
  supabase: SupabaseClient,
  args: AttemptReactivateArgs,
): Promise<WrapperResponse> {
  try {
    const { data, error } = await supabase.rpc("attempt_reactivate_row", {
      p_session_id: args.sessionId,
      p_wh_inventory_id: args.whInventoryId,
      p_new_warehouse_stock: args.newWarehouseStock,
      p_reason: args.reason,
      p_client_correlation_id: args.correlationId,
      p_source_doc: args.sourceDoc ?? null,
      p_new_expiration_date: args.newExpirationDate ?? null,
      p_new_wh_location: args.newWhLocation ?? null,
    });
    if (error) {
      const wrapped = await recordClientFailure(supabase, {
        sessionId: args.sessionId,
        whInventoryId: args.whInventoryId,
        fieldChanged: "status",
        rpcCalled: "attempt_reactivate_row",
        reason: args.reason,
        correlationId: args.correlationId,
        errorMessage: error.message,
      });
      return {
        attempt_id: wrapped.attempt_id,
        result: "network_error",
        rpc_response: null,
        error: error.message,
        rpc_called: "attempt_reactivate_row",
      };
    }
    return data as WrapperResponse;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const wrapped = await recordClientFailure(supabase, {
      sessionId: args.sessionId,
      whInventoryId: args.whInventoryId,
      fieldChanged: "status",
      rpcCalled: "attempt_reactivate_row",
      reason: args.reason,
      correlationId: args.correlationId,
      errorMessage: msg,
    });
    return {
      attempt_id: wrapped.attempt_id,
      result: "network_error",
      rpc_response: null,
      error: msg,
      rpc_called: "attempt_reactivate_row",
    };
  }
}

interface ClientFailureArgs {
  sessionId: string;
  whInventoryId: string;
  fieldChanged: "warehouse_stock" | "status";
  rpcCalled: string;
  reason: string;
  correlationId: string;
  errorMessage: string;
}

async function recordClientFailure(
  supabase: SupabaseClient,
  args: ClientFailureArgs,
): Promise<{ attempt_id: string | null }> {
  // Direct INSERT into inventory_control_attempt. RLS permits this for
  // staff roles when the parent session is open (ica_insert policy).
  // Used when the SECURITY DEFINER wrapper was never reached (network error,
  // JWT expired, edge function down). Without this path, those failures would
  // be invisible in the session log.
  try {
    const { data, error } = await supabase
      .from("inventory_control_attempt")
      .insert({
        session_id: args.sessionId,
        target_path: "by_id",
        wh_inventory_id: args.whInventoryId,
        field_changed: args.fieldChanged,
        rpc_called: args.rpcCalled,
        result: "network_error",
        error_message: args.errorMessage,
        client_correlation_id: args.correlationId,
        reason: args.reason,
      })
      .select("attempt_id")
      .single();
    if (error) return { attempt_id: null };
    return { attempt_id: (data?.attempt_id as string) ?? null };
  } catch {
    return { attempt_id: null };
  }
}
