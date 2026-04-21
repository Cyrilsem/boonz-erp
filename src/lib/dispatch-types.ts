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
