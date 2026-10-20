#!/usr/bin/env node
/**
 * PRD-145 P3-4 - lot truth at pack.
 *
 *   node scripts/prd145-lot-truth.test.mjs
 *
 * The database half (pack from a non-pinned lot moves the row's expiry and lot;
 * a warehouse edit re-pins unpacked rows; the ghost list holds a seeded 2-unit
 * lot next to a 40-unit lot; the pin preview flags it; Zero is the warehouse
 * manager's) is asserted in SQL by supabase/tests/prd145_p3_4_lot_truth.sql,
 * run after the migration in one rolled-back transaction. This script covers
 * the pack screen: the pinned lot is preselected and one tap moves the pick to
 * any live lot. Exit 0 = green.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const { pinnedFirst, allocatePreferring, fefoAllocate } = await import(
  new URL(
    "../src/app/(field)/field/packing/_lib/build-picks.ts",
    import.meta.url,
  ).href
);

// AMZ-1038 A12 Mountain Dew, 20 Oct: a 1-unit ghost lot (2027-06-10) ahead of
// the real 14-unit lot (2027-07-04) that push pinned.
const ghost = { wh_inventory_id: "ghost-0610", expiry: "2027-06-10", stock: 1 };
const real = { wh_inventory_id: "real-0704", expiry: "2027-07-04", stock: 14 };

test("FEFO alone takes the ghost lot first (the 20 Oct pick)", () => {
  assert.deepEqual(fefoAllocate([ghost, real], 3), {
    "ghost-0610": 1,
    "real-0704": 2,
  });
});

test("the pinned lot is preselected: all 3 from the real lot", () => {
  assert.deepEqual(
    pinnedFirst([ghost, real], "real-0704").map((b) => b.wh_inventory_id),
    ["real-0704", "ghost-0610"],
  );
  assert.deepEqual(allocatePreferring([ghost, real], 3, "real-0704"), {
    "real-0704": 3,
  });
});

test("no pin keeps FEFO", () => {
  assert.deepEqual(pinnedFirst([ghost, real], null), [ghost, real]);
  assert.deepEqual(allocatePreferring([ghost, real], 3, null), {
    "ghost-0610": 1,
    "real-0704": 2,
  });
});

test("one tap on a short lot takes what it has and FEFO fills the rest", () => {
  const big = { wh_inventory_id: "big-0801", expiry: "2027-08-01", stock: 40 };
  assert.deepEqual(allocatePreferring([ghost, real, big], 5, "ghost-0610"), {
    "ghost-0610": 1,
    "real-0704": 4,
  });
});

test("the pack screen wires the pin and the one-tap switch", () => {
  const page = readFileSync(
    new URL(
      "../src/app/(field)/field/packing/[machineId]/page.tsx",
      import.meta.url,
    ),
    "utf8",
  );
  assert.ok(page.includes("from_wh_inventory_id,"), "select reads the pin");
  assert.ok(
    page.includes("pinnedFirst("),
    "step 4 allocation puts the pin first",
  );
  assert.equal(
    (page.match(/pickFromLot\(/g) ?? []).length,
    3,
    "handler + 2 tables",
  );
  assert.ok(page.includes('"use this lot"'));
});
