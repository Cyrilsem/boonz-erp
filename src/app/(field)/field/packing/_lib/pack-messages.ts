/**
 * PRD-115 §2.3 - the strings the packer actually reads.
 *
 * They live in one module for two reasons. First, the copy IS the fix: the
 * incident was not that validation fired, it was that the message told the packer
 * nothing she could act on ("Activia Mix & Go: Pick total (6) exceeds planned
 * quantity (3)" - which line? and why is 6 wrong when she counted 6 units?).
 * Second, `scripts/prd115-fe-string-assertions.mjs` asserts these exact strings,
 * and an assertion that greps a 4,900-line component for a template literal is an
 * assertion that rots. Here it has one address.
 */

/**
 * The honest over-pick message (PRD-115 §2.3, acceptance 4).
 *
 * The packer in the incident had counted the same-pod REMOVE leg's 3 units into
 * her pick and got 6. She was not wrong about the physical units; she was wrong
 * about which of them the warehouse hands over. Remove legs come OUT of the
 * machine and draw nothing from the warehouse, so they never count toward a pick.
 *
 * Names the line, states the plan, and states the rule. All three, or the packer
 * is back to guessing.
 */
export function pickExceedsPlanMessage(
  lineName: string,
  plannedQty: number,
): string {
  return `${lineName}: this line plans ${plannedQty} (Remove legs are counted separately - do not add them to your pick).`;
}

/** The chip on a Remove leg rendered next to the pick it is NOT part of. */
export const REMOVE_LEG_CHIP = "counts separately";

/**
 * ONE banner replaces the per-line warning wall (PRD-115 §2.3, acceptance 3).
 * Nineteen copies of "already packed - refresh to edit" on one screen is not
 * nineteen problems, it is one: the plan moved under the packer.
 */
export function planChangedBanner(nLines: number): string {
  return `Plan changed while you were packing - ${nLines} ${
    nLines === 1 ? "line" : "lines"
  } updated.`;
}

/** The needs_reconfirm banner. M comes from v_machine_pack_status.unresolved_n. */
export function needsReconfirmBanner(nLines: number): string {
  return `Plan changed after confirm - ${nLines} ${
    nLines === 1 ? "line" : "lines"
  } to finish`;
}

/**
 * The re-pack confirm dialog copy. It is labelled destructive because it is:
 * repack_machine returns every packed line to the warehouse. In the incident this
 * was the ONLY prominent exit from a stuck confirm state, which is how a display
 * bug came within one tap of moving real stock.
 */
export const REPACK_DESTRUCTIVE_WARNING =
  "This returns ALL packed stock to the warehouse and starts the pack over.";
