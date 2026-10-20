/**
 * PRD-144 P3-1 - the lane picture for swaps, shared by the packing page
 * (warehouse) and the driver page.
 *
 * A swap lane (machine + shelf_code) can hold, on the same day:
 *   - Remove legs with source_kind 'wh'            OUT to warehouse
 *   - Remove legs with source_kind 'intra_machine' OUT to another shelf (paired
 *     by m2m_partner_id / m2m_transfer_id with an Add New on the destination)
 *   - Add New legs with source_kind 'intra_machine' IN from another shelf
 *   - Add New / Refill legs from the warehouse      IN from warehouse
 *
 * The old Swaps section paired the FIRST Remove on a shelf with the shelf's
 * Adds, so a second Remove (AMZ-1029 A07 Popit Cola, 20 Oct) showed nowhere.
 * Here every leg on a lane lands on exactly one lane card.
 *
 * Read-only grouping: no RPC and no writes.
 */

export interface LaneLeg {
  dispatch_id: string;
  /** refill_dispatching.action: Refill | Add New | Add | Remove | ... */
  action: string;
  source_kind: string | null;
  shelf_code: string | null;
  quantity: number;
  boonz_name: string | null;
  pod_name: string | null;
  pod_product_id: string | null;
  /** Machine-to-machine legs belong to the M2M section, never to a lane card. */
  is_m2m: boolean;
  m2m_partner_id: string | null;
  m2m_transfer_id: string | null;
  comment?: string | null;
}

export interface LaneMove<T> {
  item: T;
  /** The other end of the move (destination for OUT, source for IN); null if unknown. */
  otherShelf: string | null;
  /** The paired leg on the other shelf, when it is in the same list. */
  partner: T | null;
}

export interface Lane<T> {
  shelf_code: string;
  outWarehouse: T[];
  outShelf: LaneMove<T>[];
  inShelf: LaneMove<T>[];
  inWarehouse: T[];
  /** Only warehouse Remove legs and nothing coming in. */
  removeOnly: boolean;
  header: string;
}

export const REMOVE_ONLY_TITLE = "Remove only, lane goes empty";

const isRemoveAction = (a: string) =>
  a === "Remove" || a === "Machine To Warehouse";
const isIntra = (l: LaneLeg) => l.source_kind === "intra_machine";

/** One name for a set of legs: the flavour if there is one, else the pod. */
function setLabel(legs: LaneLeg[]): string {
  const flavours = [
    ...new Set(legs.map((l) => l.boonz_name ?? l.pod_name ?? "?")),
  ];
  if (flavours.length === 1) return flavours[0];
  const pods = [...new Set(legs.map((l) => l.pod_name ?? l.boonz_name ?? "?"))];
  return pods.join(" + ");
}

const qty = (n: number) => String(Math.round(n * 100) / 100);
const sum = (legs: LaneLeg[]) =>
  legs.reduce((s, l) => s + (l.quantity || 0), 0);

/** Totals per other shelf, in shelf order. */
function byShelf(moves: { leg: LaneLeg; otherShelf: string | null }[]) {
  const m = new Map<string, number>();
  for (const mv of moves) {
    const k = mv.otherShelf ?? "another shelf";
    m.set(k, (m.get(k) ?? 0) + (mv.leg.quantity || 0));
  }
  return [...m.entries()].sort((a, b) => a[0].localeCompare(b[0]));
}

/**
 * "A07: Popit - Original Cola out (7 to warehouse), Barebells in (14 from A11)"
 */
export function laneHeader(
  shelf: string,
  outWh: LaneLeg[],
  outShelf: { leg: LaneLeg; otherShelf: string | null }[],
  inShelf: { leg: LaneLeg; otherShelf: string | null }[],
  inWh: LaneLeg[],
): string {
  const parts: string[] = [];
  const outLegs = [...outWh, ...outShelf.map((m) => m.leg)];
  if (outLegs.length > 0) {
    const where = [
      ...(outWh.length > 0 ? [`${qty(sum(outWh))} to warehouse`] : []),
      ...byShelf(outShelf).map(([s, n]) => `${qty(n)} to ${s}`),
    ];
    parts.push(`${setLabel(outLegs)} out (${where.join(", ")})`);
  }
  const inLegs = [...inShelf.map((m) => m.leg), ...inWh];
  if (inLegs.length > 0) {
    const where = [
      ...byShelf(inShelf).map(([s, n]) => `${qty(n)} from ${s}`),
      ...(inWh.length > 0 ? [`${qty(sum(inWh))} from warehouse`] : []),
    ];
    parts.push(`${setLabel(inLegs)} in (${where.join(", ")})`);
  }
  return `${shelf}: ${parts.join(", ")}`;
}

/** "Move A11 to A07" in the leg comment, for legs written without a partner id. */
function shelvesFromComment(
  c: string | null | undefined,
): [string, string] | null {
  const m = /Move\s+([A-Z]\d{1,2})\s+to\s+([A-Z]\d{1,2})/i.exec(c ?? "");
  return m ? [m[1].toUpperCase(), m[2].toUpperCase()] : null;
}

/**
 * Splits a machine-day's legs into lane cards and the rest.
 *
 * A lane gets a card when it has a Remove leg or an intra_machine leg. One
 * exception keeps the PRD-115 §2.3 layout: a lane whose legs are only Refills
 * plus Remove legs of the same pod (an expiry pull-and-refill of one product,
 * not a swap) stays in "Pack these items", where the Remove sits next to its
 * Refill. Machine-to-machine legs are always left in `rest`.
 */
export function buildLanes<T>(
  items: T[],
  toLeg: (t: T) => LaneLeg,
): { lanes: Lane<T>[]; rest: T[] } {
  const legOf = new Map<T, LaneLeg>(items.map((t) => [t, toLeg(t)]));
  const byId = new Map<string, T>();
  for (const t of items) byId.set(legOf.get(t)!.dispatch_id, t);

  const byLane = new Map<string, T[]>();
  const rest: T[] = [];
  for (const t of items) {
    const l = legOf.get(t)!;
    if (l.is_m2m || !l.shelf_code) {
      rest.push(t);
      continue;
    }
    const arr = byLane.get(l.shelf_code) ?? [];
    arr.push(t);
    byLane.set(l.shelf_code, arr);
  }

  const partnerOf = (l: LaneLeg): T | null => {
    if (l.m2m_partner_id && byId.has(l.m2m_partner_id))
      return byId.get(l.m2m_partner_id)!;
    if (l.m2m_transfer_id) {
      for (const t of items) {
        const o = legOf.get(t)!;
        if (
          o.dispatch_id !== l.dispatch_id &&
          o.m2m_transfer_id === l.m2m_transfer_id
        )
          return t;
      }
    }
    return null;
  };

  const lanes: Lane<T>[] = [];
  for (const [shelf, laneItems] of [...byLane.entries()].sort((a, b) =>
    a[0].localeCompare(b[0]),
  )) {
    const legs = laneItems.map((t) => legOf.get(t)!);
    const hasRemove = legs.some((l) => isRemoveAction(l.action));
    const hasIntra = legs.some(isIntra);
    if (!hasRemove && !hasIntra) {
      rest.push(...laneItems);
      continue;
    }
    const refillPods = new Set(
      legs.filter((l) => l.action === "Refill").map((l) => l.pod_product_id),
    );
    const samePodRefillOnly =
      !hasIntra &&
      refillPods.size > 0 &&
      legs.every(
        (l) =>
          l.action === "Refill" ||
          (isRemoveAction(l.action) && refillPods.has(l.pod_product_id)),
      );
    if (samePodRefillOnly) {
      rest.push(...laneItems);
      continue;
    }

    const lane: Lane<T> = {
      shelf_code: shelf,
      outWarehouse: [],
      outShelf: [],
      inShelf: [],
      inWarehouse: [],
      removeOnly: false,
      header: "",
    };
    for (const t of laneItems) {
      const l = legOf.get(t)!;
      if (isRemoveAction(l.action)) {
        if (isIntra(l)) {
          const p = partnerOf(l);
          lane.outShelf.push({
            item: t,
            partner: p,
            otherShelf: p
              ? legOf.get(p)!.shelf_code
              : (shelvesFromComment(l.comment)?.[1] ?? null),
          });
        } else {
          lane.outWarehouse.push(t);
        }
      } else if (isIntra(l)) {
        const p = partnerOf(l);
        lane.inShelf.push({
          item: t,
          partner: p,
          otherShelf: p
            ? legOf.get(p)!.shelf_code
            : (shelvesFromComment(l.comment)?.[0] ?? null),
        });
      } else {
        // Every other non-M2M leg on a swap lane comes from the warehouse
        // (Add New, Refill, Add, and any legacy action), so nothing is dropped.
        lane.inWarehouse.push(t);
      }
    }
    lane.removeOnly =
      lane.outShelf.length === 0 &&
      lane.inShelf.length === 0 &&
      lane.inWarehouse.length === 0;
    const L = (t: T) => legOf.get(t)!;
    lane.header = laneHeader(
      shelf,
      lane.outWarehouse.map(L),
      lane.outShelf.map((m) => ({ leg: L(m.item), otherShelf: m.otherShelf })),
      lane.inShelf.map((m) => ({ leg: L(m.item), otherShelf: m.otherShelf })),
      lane.inWarehouse.map(L),
    );
    lanes.push(lane);
  }
  return { lanes, rest };
}

/** Every leg on a lane card, in card order. */
export function laneItems<T>(lane: Lane<T>): T[] {
  return [
    ...lane.outWarehouse,
    ...lane.outShelf.map((m) => m.item),
    ...lane.inShelf.map((m) => m.item),
    ...lane.inWarehouse,
  ];
}
