#!/usr/bin/env node
/**
 * PRD-144 P0-1 - the pack screen picks array on a multi-lot product.
 *
 *   node scripts/prd144-pack-multilot.test.mjs
 *
 * Imports the shipped helper (Node 22 strips the TypeScript types). Exit 0 =
 * green, exit 1 = red. The browser half is scripts/prd144-pack-multilot.e2e.mjs.
 */
import assert from "node:assert/strict";
import { test } from "node:test";

const { fefoAllocate, buildPackPicks } = await import(
  new URL("../src/app/(field)/field/packing/_lib/build-picks.ts", import.meta.url).href
);

const BP = "bp-nutella-t12";
const lotA = { wh_inventory_id: "lot-a", expiry: "2026-11-01", stock: 2 };
const lotB = { wh_inventory_id: "lot-b", expiry: "2026-12-01", stock: 10 };
const lotC = { wh_inventory_id: "lot-c", expiry: "2027-01-01", stock: 7 };
const lotEmpty = { wh_inventory_id: "lot-0", expiry: "2026-10-25", stock: 0 };
const never = () => false;

test("plan 5, lot A has 2, lot B has 10: picks [2,3] in FEFO order", () => {
  const alloc = fefoAllocate([lotB, lotA], 5);
  const picks = buildPackPicks([{ boonzProductId: BP, batches: [lotB, lotA] }], alloc, never);
  assert.deepEqual(picks.map((p) => [p.wh_inventory_id, p.qty]), [["lot-a", 2], ["lot-b", 3]]);
  assert.ok(picks.every((p) => p.boonz_product_id === BP));
});

test("a third lot left at 0 is skipped, not fatal (the regression)", () => {
  const alloc = fefoAllocate([lotA, lotB, lotC], 5);
  assert.equal(alloc["lot-c"], undefined);
  const picks = buildPackPicks([{ boonzProductId: BP, batches: [lotA, lotB, lotC] }], alloc, never);
  assert.deepEqual(picks.map((p) => p.qty), [2, 3]);
});

test("a lot with 0 pickable is skipped by FEFO", () => {
  const alloc = fefoAllocate([lotEmpty, lotA, lotB], 5);
  assert.deepEqual(alloc, { "lot-a": 2, "lot-b": 3 });
});

test("a frozen slice is left out, the rest still packs", () => {
  const picks = buildPackPicks(
    [{ boonzProductId: BP, batches: [lotA, lotB] }],
    { "lot-a": 2, "lot-b": 3 },
    (_bp, exp) => exp === "2026-11-01",
  );
  assert.deepEqual(picks.map((p) => [p.wh_inventory_id, p.qty]), [["lot-b", 3]]);
});

test("mix line: one pick per variant lot, zero variants dropped", () => {
  const picks = buildPackPicks(
    [
      { boonzProductId: "v1", batches: [lotA] },
      { boonzProductId: "v2", batches: [lotB, lotC] },
    ],
    { "lot-a": 2, "lot-b": 0, "lot-c": 4 },
    never,
  );
  assert.deepEqual(picks.map((p) => [p.boonz_product_id, p.qty]), [["v1", 2], ["v2", 4]]);
});
