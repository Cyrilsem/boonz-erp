/**
 * Canonical set of dispatch action values stored in refill_dispatching.action
 * and refill_plan_output.action. Keep in sync with push_plan_to_dispatch RPC.
 */
export type DispatchAction = "Refill" | "Add New" | "Remove";

/**
 * PRD-113 — an in-machine move is not a warehouse return.
 *
 * A swap that relocates product between two shelves of the SAME machine writes a
 * Remove leg and an Add New leg. The Remove is NOT a return: those units never
 * leave the machine. Rendering it as "Remove" is what confused the driver on
 * MC-2004-0100-O1 (plan 2026-08-07), and rendering its partner as "Add New" lost
 * the "move with machine" intent entirely.
 *
 * The authority is the backend: `refill_dispatching.is_internal_move`, written by
 * `tg_mark_internal_move_pair`, with `internal_move_cleared_at` as the durable
 * human override. The FE never re-derives the pairing rule — it reads the flag.
 * The comment sniffing below is DISPLAY-ONLY backfill for rows written before the
 * column existed (PRD-113 fix 4), and never feeds a write or an approval.
 */
export interface InternalMoveFields {
  action?: string | null;
  is_internal_move?: boolean | null;
  internal_move_cleared_at?: string | null;
  comment?: string | null;
}

/**
 * Legacy in-machine-move comment conventions, for display-only backfill.
 *
 * Deliberately anchored on a SHELF-CODE target (A01…A99). The live comment corpus
 * also contains "Move to AstroLabs", "Move to IRIS", "Move to NOOK" — those are
 * moves to another VENUE, i.e. genuine departures from the machine, and labelling
 * them "Move within machine" would be exactly the wrong error.
 */
const LEGACY_INTERNAL_MOVE_COMMENT = [
  /\[internal[- ]move\]/i,
  // "Move to A2", "Moved to A13", "move ALL 8 Tamreem from A16 into A04"
  /\b(?:move[ds]?|consolidat\w*)\b[^.;|]*\b(?:in)?to\s+A\d{1,2}\b/i,
  // "move Krambals A12 -> A02 (off A12)"
  /\bA\d{1,2}\s*(?:->|→)\s*A\d{1,2}\b/,
  /\brelocated\s+(?:in)?to\s+A\d{1,2}\b/i,
  /\bin-machine move\b/i,
  /\bINTERNAL MOVE\b/,
];

/** True when this leg relocates product to another shelf of the same machine. */
export function isInternalMoveLeg(row: InternalMoveFields): boolean {
  // A human ruling that this is a genuine warehouse return outranks everything.
  if (row.internal_move_cleared_at) return false;
  if (row.is_internal_move) return true;
  const c = row.comment;
  if (!c) return false;
  return LEGACY_INTERNAL_MOVE_COMMENT.some((re) => re.test(c));
}

/**
 * The chip a dispatch leg should carry. An internal-move Remove never reads
 * "REMOVE" or "RETURN" — the units are staying in the machine.
 */
export function dispatchActionChip(row: InternalMoveFields): {
  label: string;
  tone: "move" | "remove" | "add" | "refill";
} {
  if (isInternalMoveLeg(row) && row.action === "Remove") {
    return { label: "MOVE WITHIN MACHINE", tone: "move" };
  }
  if (row.action === "Remove") return { label: "REMOVE", tone: "remove" };
  if (row.action === "Add New") return { label: "ADD NEW", tone: "add" };
  return { label: "REFILL", tone: "refill" };
}

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
