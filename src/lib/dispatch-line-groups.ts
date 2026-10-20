/**
 * PRD-145 P3-2 - a dispatch line, not a lot row.
 *
 * pack_dispatch_line splits one plan line into one refill_dispatching row per
 * warehouse lot: the first lot stays on the row, each further lot is a child
 * row with parent_dispatch_id. The edit dialog showed one lot row, so the team
 * read "6 became 5" (AMZ-1038 A12 Mountain Dew, 20 Oct: 1 + 2 for a plan of 3).
 *
 * A line is the group (machine_id, shelf_id, boonz_product_id, action,
 * source_kind, coalesce(parent_dispatch_id, dispatch_id)). pack_dispatch_line
 * writes its child rows without source_kind, so a child takes its root's.
 * amend_dispatch_line_total re-derives the same group server-side.
 */

export interface LineRow {
  dispatch_id: string;
  parent_dispatch_id: string | null;
  machine_id: string;
  shelf_id: string | null;
  boonz_product_id: string | null;
  action: string;
  source_kind: string | null;
  quantity: number;
  filled_quantity: number | null;
  packed: boolean;
  expiry_date: string | null;
}

export interface LineGroupKey {
  machine_id: string;
  shelf_id: string;
  boonz_product_id: string;
  action: string;
  source_kind: string;
  root_dispatch_id: string;
}

export interface LineLot {
  dispatch_id: string;
  expiry_date: string | null;
  qty: number;
}

export interface LineGroup {
  key: LineGroupKey;
  /** Packed line: units packed across the lot rows. Unpacked: the planned quantity. */
  total: number;
  packed: boolean;
  /** Lot rows, latest expiry first (the order a lower takes them back). */
  lots: LineLot[];
}

export const lineRootId = (
  r: Pick<LineRow, "dispatch_id" | "parent_dispatch_id">,
) => r.parent_dispatch_id ?? r.dispatch_id;

const rowQty = (r: LineRow) =>
  r.packed ? Math.max(0, r.filled_quantity ?? 0) : Math.max(0, r.quantity);

/** Latest expiry first, undated first (the order the RPC lowers in). */
const byExpiryDesc = (a: LineLot, b: LineLot) =>
  a.expiry_date === b.expiry_date
    ? 0
    : a.expiry_date === null
      ? -1
      : b.expiry_date === null
        ? 1
        : b.expiry_date.localeCompare(a.expiry_date);

/** Groups refill_dispatching rows into lines. Rows without a shelf or product are skipped. */
export function groupLines(rows: LineRow[]): LineGroup[] {
  const roots = new Map(
    rows.filter((r) => !r.parent_dispatch_id).map((r) => [r.dispatch_id, r]),
  );
  const groups = new Map<string, LineGroup>();
  for (const r of rows) {
    if (!r.shelf_id || !r.boonz_product_id) continue;
    const rootId = lineRootId(r);
    const sourceKind =
      roots.get(rootId)?.source_kind ?? r.source_kind ?? "unknown";
    const key: LineGroupKey = {
      machine_id: r.machine_id,
      shelf_id: r.shelf_id,
      boonz_product_id: r.boonz_product_id,
      action: r.action,
      source_kind: sourceKind,
      root_dispatch_id: rootId,
    };
    const k = Object.values(key).join("|");
    const g = groups.get(k) ?? { key, total: 0, packed: false, lots: [] };
    g.total += rowQty(r);
    g.packed = g.packed || r.packed;
    g.lots.push({
      dispatch_id: r.dispatch_id,
      expiry_date: r.expiry_date,
      qty: rowQty(r),
    });
    groups.set(k, g);
  }
  for (const g of groups.values()) g.lots.sort(byExpiryDesc);
  return [...groups.values()];
}

/**
 * The lot quantities a lower to newTotal leaves (mirror of the RPC: latest
 * expiry gives back first; a lot that reaches 0 drops off the line).
 */
export function planLowerTotal(lots: LineLot[], newTotal: number): LineLot[] {
  let give = lots.reduce((s, l) => s + l.qty, 0) - newTotal;
  const out: LineLot[] = [];
  for (const l of [...lots].sort(byExpiryDesc)) {
    const take = Math.max(0, Math.min(give, l.qty));
    give -= take;
    if (l.qty - take > 0) out.push({ ...l, qty: l.qty - take });
  }
  return out;
}
