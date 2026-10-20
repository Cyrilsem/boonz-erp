#!/usr/bin/env node
/**
 * PRD-144 P3-1 - lane cards for swaps on the packing and driver pages.
 *
 *   node scripts/prd144-lane-cards.test.mjs
 *
 * Imports the shipped helper (Node 22 strips the TypeScript types) and runs it
 * over the live dispatch of 2026-10-19 and 2026-10-20
 * (scripts/fixtures/prd144-dispatch-2026-10-19_20.json). Exit 0 = green.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const { buildLanes, laneItems, REMOVE_ONLY_TITLE } = await import(
  new URL("../src/lib/dispatch-lanes.ts", import.meta.url).href
);

const fixture = JSON.parse(
  readFileSync(
    new URL("./fixtures/prd144-dispatch-2026-10-19_20.json", import.meta.url),
    "utf8",
  ),
);
const legs = (day, machine) => fixture.days[day][machine];
const lanesOf = (day, machine) => buildLanes(legs(day, machine), (l) => l);
const lane = (day, machine, shelf) =>
  lanesOf(day, machine).lanes.find((l) => l.shelf_code === shelf);

for (const day of ["2026-10-19", "2026-10-20"]) {
  test(`${day}: every include=true row lands exactly once, and every Remove or intra_machine row is on a lane card`, () => {
    let machines = 0;
    let onCards = 0;
    for (const [machine, rows] of Object.entries(fixture.days[day])) {
      machines += 1;
      const { lanes, rest } = buildLanes(rows, (l) => l);
      const placed = [...lanes.flatMap(laneItems), ...rest].map(
        (l) => l.dispatch_id,
      );
      assert.equal(placed.length, rows.length, `${machine}: row count`);
      assert.equal(
        new Set(placed).size,
        rows.length,
        `${machine}: a row is on two cards`,
      );
      const cardIds = new Set(
        lanes.flatMap(laneItems).map((l) => l.dispatch_id),
      );
      onCards += cardIds.size;
      for (const r of rows) {
        if (r.is_m2m) continue;
        if (r.source_kind === "intra_machine") {
          assert.ok(
            cardIds.has(r.dispatch_id),
            `${machine} ${r.shelf_code}: intra leg ${r.dispatch_id} off-card`,
          );
        }
        if (r.action === "Remove" && !cardIds.has(r.dispatch_id)) {
          // Only the PRD-115 same-pod Refill pairing may keep a Remove off a card.
          const refill = rows.find(
            (o) =>
              o.shelf_code === r.shelf_code &&
              o.action === "Refill" &&
              o.pod_product_id === r.pod_product_id,
          );
          assert.ok(
            refill,
            `${machine} ${r.shelf_code}: Remove ${r.dispatch_id} dropped`,
          );
        }
      }
      // Every lane card leg is on its own lane.
      for (const ln of lanes) {
        for (const it of laneItems(ln))
          assert.equal(it.shelf_code, ln.shelf_code);
      }
    }
    assert.ok(machines > 0 && onCards > 0, "fixture is empty");
  });
}

test("AMZ-1029 A07: the Popit Cola wh Remove is on the card (the reported miss)", () => {
  const a07 = lane("2026-10-20", "AMZ-1029-3003-O1", "A07");
  assert.equal(
    a07.header,
    "A07: Popit - Original Cola out (7 to warehouse), Barebells in (14 from A11)",
  );
  assert.deepEqual(
    a07.outWarehouse.map((l) => [l.boonz_name, l.quantity]),
    [["Popit - Original Cola", 7]],
  );
  assert.equal(a07.outShelf.length, 0);
  assert.deepEqual(
    a07.inShelf.map((m) => m.otherShelf),
    ["A11", "A11", "A11"],
  );
  assert.equal(a07.inWarehouse.length, 0);
});

test("AMZ-1029 A11: intra Removes are OUT to A07 (no 'counts separately' swap Remove), Red Bull IN from warehouse", () => {
  const a11 = lane("2026-10-20", "AMZ-1029-3003-O1", "A11");
  assert.equal(
    a11.header,
    "A11: Barebells out (14 to A07), Red Bull in (20 from warehouse)",
  );
  assert.equal(a11.outWarehouse.length, 0);
  assert.equal(a11.outShelf.length, 3);
  assert.ok(
    a11.outShelf.every(
      (m) => m.otherShelf === "A07" && m.partner?.shelf_code === "A07",
    ),
  );
  assert.equal(a11.inWarehouse.length, 4);
});

test("NOOK-1019 A12: wh and intra Removes both shown, Krambals IN from warehouse; A13 shows the other end", () => {
  const a12 = lane("2026-10-20", "NOOK-1019-0200-B1", "A12");
  assert.equal(
    a12.header,
    "A12: Popit Mix out (4 to warehouse, 6 to A13), Krambals in (6 from warehouse)",
  );
  assert.equal(a12.outWarehouse.length, 2);
  assert.equal(a12.outShelf.length, 2);
  const a13 = lane("2026-10-20", "NOOK-1019-0200-B1", "A13");
  assert.ok(a13, "destination lane A13 has a card");
  assert.deepEqual(
    a13.inShelf.map((m) => m.otherShelf),
    ["A12", "A12"],
  );
  // The move's two ends are the same pair, seen from each lane.
  const pairs = a12.outShelf
    .map((m) => [m.item.dispatch_id, m.partner.dispatch_id])
    .sort();
  const back = a13.inShelf
    .map((m) => [m.partner.dispatch_id, m.item.dispatch_id])
    .sort();
  assert.deepEqual(pairs, back);
});

test("a lane with only wh Removes renders as a remove-only card, not hidden", () => {
  const rows = [
    {
      dispatch_id: "r1",
      action: "Remove",
      source_kind: "wh",
      shelf_code: "B02",
      quantity: 3,
      boonz_name: "Oreo - Original",
      pod_name: "Oreo",
      pod_product_id: "p1",
      is_m2m: false,
      m2m_partner_id: null,
      m2m_transfer_id: null,
    },
  ];
  const { lanes, rest } = buildLanes(rows, (l) => l);
  assert.equal(rest.length, 0);
  assert.equal(lanes.length, 1);
  assert.ok(lanes[0].removeOnly);
  assert.equal(lanes[0].header, "B02: Oreo - Original out (3 to warehouse)");
  assert.equal(REMOVE_ONLY_TITLE, "Remove only, lane goes empty");
});

test("M2M legs and plain refills stay off lane cards", () => {
  const rows = [
    {
      dispatch_id: "m1",
      action: "Remove",
      source_kind: "m2m",
      shelf_code: "A01",
      quantity: 2,
      boonz_name: "X",
      pod_name: "X",
      pod_product_id: "p",
      is_m2m: true,
      m2m_partner_id: null,
      m2m_transfer_id: "t",
    },
    {
      dispatch_id: "f1",
      action: "Refill",
      source_kind: "wh",
      shelf_code: "A02",
      quantity: 5,
      boonz_name: "Y",
      pod_name: "Y",
      pod_product_id: "q",
      is_m2m: false,
      m2m_partner_id: null,
      m2m_transfer_id: null,
    },
  ];
  const { lanes, rest } = buildLanes(rows, (l) => l);
  assert.equal(lanes.length, 0);
  assert.deepEqual(
    rest.map((r) => r.dispatch_id),
    ["m1", "f1"],
  );
});
