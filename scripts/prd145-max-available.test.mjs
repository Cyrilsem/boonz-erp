#!/usr/bin/env node
/**
 * PRD-145 P3-3 - "Max available" in the dispatch edit dialog counts the units
 * already packed on the line being edited.
 *
 *   node scripts/prd145-max-available.test.mjs
 *
 * Imports the shipped helper (Node 22 strips the TypeScript types). Exit 0 = green.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const { lineMaxAvailable, packedOnLine } = await import(
  new URL("../src/lib/dispatch-line-edit.ts", import.meta.url).href
);

test("Coke Regular: 6 packed from an 11 lot => max 11 (the dialog said 5)", () => {
  const lotLeft = 11 - 6;
  assert.equal(
    lineMaxAvailable(lotLeft, [{ packed: true, filled_quantity: 6 }]),
    11,
  );
});

test("an unpacked line is capped by the stock left, as before", () => {
  assert.equal(
    lineMaxAvailable(5, [{ packed: false, filled_quantity: null }]),
    5,
  );
});

test("a line split over two lots counts both lot rows (AMZ-1038 A12 Mountain Dew, 1 + 2)", () => {
  const rows = [
    { packed: true, filled_quantity: 1 },
    { packed: true, filled_quantity: 2 },
  ];
  assert.equal(packedOnLine(rows), 3);
  assert.equal(lineMaxAvailable(4, rows), 7);
});

test("over-committed stock never makes the cap smaller than what the line holds", () => {
  assert.equal(lineMaxAvailable(-3, [{ packed: true, filled_quantity: 6 }]), 6);
});

test("the packing page feeds both edit buttons through lineMaxAvailable with the card's lot rows", () => {
  const page = readFileSync(
    new URL(
      "../src/app/(field)/field/packing/[machineId]/page.tsx",
      import.meta.url,
    ),
    "utf8",
  );
  const sites =
    page.match(
      /maxAvailable: \w+\.from_warehouse_name\s*\?\s*lineMaxAvailable\(/g,
    ) ?? [];
  assert.equal(sites.length, 2);
  assert.equal((page.match(/cardLotRows\((addLine|line)\)/g) ?? []).length, 2);
});
