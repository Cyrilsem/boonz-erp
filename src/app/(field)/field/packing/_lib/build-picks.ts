/**
 * PRD-144 P0-1 - the pack_dispatch_line picks array, built in one place.
 *
 * The bug this fixes: on a product with several warehouse lots, FEFO fills the
 * first lot(s) and leaves later lots at 0. The pick loop treated a 0-qty lot as
 * "abandon the whole line" (an early return), so the Save tap sent nothing and
 * said nothing. A lot with 0 picked, or a frozen (already picked up) slice, is
 * simply left out of the picks.
 *
 * Kept free of React and Supabase so `scripts/prd144-pack-multilot.test.mjs`
 * can import it directly.
 */

export interface PickBatch {
  wh_inventory_id: string;
  expiry: string | null;
  stock: number;
}

export interface PackPick {
  wh_inventory_id: string;
  qty: number;
  boonz_product_id: string;
}

/** Expiry ASC NULLS LAST, the warehouse FEFO order. */
export function byExpiryAsc(
  a: { expiry: string | null },
  b: { expiry: string | null },
): number {
  if (a.expiry === b.expiry) return 0;
  if (!a.expiry) return 1;
  if (!b.expiry) return -1;
  return a.expiry < b.expiry ? -1 : 1;
}

/**
 * FEFO-allocate `qty` across lots, earliest expiry first, skipping lots with 0
 * stock. Lots that receive nothing are absent from the result.
 */
export function fefoAllocate(
  batches: PickBatch[],
  qty: number,
): Record<string, number> {
  const alloc: Record<string, number> = {};
  let remaining = qty;
  for (const b of [...batches].sort(byExpiryAsc)) {
    if (remaining <= 0) break;
    const take = Math.min(Math.max(0, b.stock), remaining);
    if (take > 0) {
      alloc[b.wh_inventory_id] = take;
      remaining -= take;
    }
  }
  return alloc;
}

/**
 * PRD-145 P3-4: the lot push pinned goes first, then FEFO. Lots of a product
 * can differ from what the plan pinned (a ghost tail lot), so the pinned lot is
 * the preselection and the packer can move the whole pick to any live lot.
 */
export function pinnedFirst<T extends { wh_inventory_id: string }>(
  batches: T[],
  pinnedId: string | null | undefined,
): T[] {
  if (!pinnedId) return batches;
  const pinned = batches.filter((b) => b.wh_inventory_id === pinnedId);
  return [...pinned, ...batches.filter((b) => b.wh_inventory_id !== pinnedId)];
}

/**
 * Allocate `qty` with `preferredId` first (up to its stock), the rest FEFO.
 * The one-tap "all from this lot" on the pack screen.
 */
export function allocatePreferring(
  batches: PickBatch[],
  qty: number,
  preferredId: string | null,
): Record<string, number> {
  const preferred = batches.find((b) => b.wh_inventory_id === preferredId);
  const first = preferred ? Math.min(Math.max(0, preferred.stock), qty) : 0;
  const rest = fefoAllocate(
    batches.filter((b) => b.wh_inventory_id !== preferredId),
    qty - first,
  );
  return preferred && first > 0
    ? { [preferred.wh_inventory_id]: first, ...rest }
    : rest;
}

/**
 * The picks for one line. `groups` is one entry per boonz product (one for a
 * single-product line, one per variant on a mix line). Lots with 0 picked and
 * frozen slices are skipped, never fatal. Picks come out in FEFO order.
 */
export function buildPackPicks(
  groups: { boonzProductId: string; batches: PickBatch[] }[],
  qtyByBatch: Record<string, number> | undefined,
  isFrozen: (boonzProductId: string, expiry: string | null) => boolean,
): PackPick[] {
  const picks: PackPick[] = [];
  for (const g of groups) {
    for (const b of [...g.batches].sort(byExpiryAsc)) {
      const qty = qtyByBatch?.[b.wh_inventory_id] ?? 0;
      if (qty <= 0) continue;
      if (isFrozen(g.boonzProductId, b.expiry)) continue;
      picks.push({
        wh_inventory_id: b.wh_inventory_id,
        qty,
        boonz_product_id: g.boonzProductId,
      });
    }
  }
  return picks;
}
