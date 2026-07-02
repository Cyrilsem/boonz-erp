/**
 * Canonical set of dispatch action values stored in refill_dispatching.action
 * and refill_plan_output.action. Keep in sync with push_plan_to_dispatch RPC.
 */
export type DispatchAction = "Refill" | "Add New" | "Remove";

/**
 * Expiry warning enum — mirrors the CHECK constraint on
 * refill_dispatching.expiry_warning and refill_plan_output.expiry_warning.
 */
export type ExpiryWarning = "expiring_soon" | "expired" | "no_expiry";

/**
 * Driver UI action state for a dispatching line (separate from the plan
 * action stored in the DB — this is the outcome the driver records).
 */
export type LineOutcome = "added" | "returned" | null;

/**
 * push_plan_to_dispatch v7 (v7_prd071_autopair_m2m) jsonb result shape.
 * Keep in sync with the RPC's final jsonb_build_object.
 */
export interface PushPlanResult {
  status?: "ok" | "error" | "conservation_violation";
  machine?: string;
  lines_pushed?: number;
  lines_skipped_null_product?: number;
  lines_preserved_manual_edit?: number;
  lines_pinned_at_plan_time?: number;
  remove_split_lines?: number;
  procurement_gaps_logged?: number;
  m2m_transfer_pairs?: number;
  m2m_transfer_deferred?: number;
  m2m_transfer_skipped?: number;
  error?: string;
  reason?: string;
  rpc_version?: string;
}

/**
 * Render the push result as a toast string. The RPC returns jsonb (an object),
 * NOT a number — reading it as a number always produced "0 lines" (PRD-072).
 */
export function pushResultToToast(
  result: unknown,
  rpcErrorMessage?: string | null,
): string {
  if (rpcErrorMessage) return `⚠️ Push failed: ${rpcErrorMessage}`;
  const r =
    result && typeof result === "object" ? (result as PushPlanResult) : null;
  if (!r || r.status === "error") {
    return `⚠️ Push failed: ${r?.error ?? "no result from push_plan_to_dispatch"}`;
  }
  if (r.status === "conservation_violation") {
    return `⛔ Push stopped: ${r.reason ?? "conservation violation (see stitch_leakage)"}`;
  }
  const count = r.lines_pushed ?? 0;
  const extras: string[] = [];
  if (r.lines_preserved_manual_edit)
    extras.push(`${r.lines_preserved_manual_edit} preserved`);
  if (r.m2m_transfer_pairs)
    extras.push(
      `${r.m2m_transfer_pairs} M2M pair${r.m2m_transfer_pairs !== 1 ? "s" : ""}`,
    );
  const tail = extras.length ? ` (${extras.join(", ")})` : "";
  return `✅ ${count} line${count !== 1 ? "s" : ""} pushed to dispatch${tail}`;
}
