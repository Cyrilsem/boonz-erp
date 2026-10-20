/**
 * PRD-145 P3-3 - the quantity cap in the dispatch edit dialog.
 *
 * pack_dispatch_line moves the packed units out of warehouse_stock, so the
 * stock left on the lot no longer counts them. A cap of "stock left" alone
 * refused to keep a packed line at its own size (Coke Regular, AMZ-1029 A13,
 * 20 Oct: 6 packed from an 11 lot, the dialog said max 5). The units already
 * packed on the line being edited are available to that same line.
 */

/** One refill_dispatching row of a line (a line splits into one row per lot at pack). */
export interface LineLotRow {
  packed: boolean;
  filled_quantity: number | null;
}

/** Units already packed across the line's lot rows. */
export function packedOnLine(rows: LineLotRow[]): number {
  return rows.reduce(
    (s, r) => s + (r.packed ? Math.max(0, r.filled_quantity ?? 0) : 0),
    0,
  );
}

/** Max quantity for the line: stock still on the lot(s) plus what this line already holds. */
export function lineMaxAvailable(
  remainingStock: number,
  rows: LineLotRow[],
): number {
  return Math.max(0, remainingStock) + packedOnLine(rows);
}
