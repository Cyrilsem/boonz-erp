#!/usr/bin/env node
/**
 * PRD-145 P3-5 - a zero-unit line is not a delivery.
 *
 *   node scripts/prd145-pack-zero.test.mjs
 *
 * The RPC behaviour (pack 0 => not_filled and item_added false; receive 0 on a
 * packed line => not_filled, units back on the lot, no second receive; driver
 * not_done accepted on a picked_up 0-filled row; amend void accepted and
 * credits nothing; the 20 Oct ea944182 shape has an exit) is asserted in SQL by
 * supabase/tests/prd145_p3_5_pack_zero.sql, run after the migration in one
 * rolled-back transaction. This script asserts the shipped sources: the
 * migration carries each rule, and the driver page query excludes the row.
 * Exit 0 = green.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const mig = read(
  "supabase/migrations/20261020160000_prd145_p3_5_zero_pack_not_delivery.sql",
);
const sqlTest = read("supabase/tests/prd145_p3_5_pack_zero.sql");
const driver = read("src/app/(field)/field/dispatching/[machineId]/page.tsx");

test("pack 0 => not_filled and item_added=false on both zero paths", () => {
  const hits = mig.match(/item_added\s+= false,\s+-- PRD-145 P3-5/g) ?? [];
  assert.equal(hits.length, 2);
  assert.match(
    sqlTest,
    /ok1 := rd\.pack_outcome = 'not_filled' AND rd\.filled_quantity = 0 AND NOT rd\.item_added/,
  );
});

test("receive 0 on a fill line is not_filled, never item_added, and cannot be received twice", () => {
  assert.ok(
    mig.includes("item_added = NOT (v_is_fill AND p_filled_quantity = 0)"),
  );
  assert.ok(mig.includes("WHEN p_filled_quantity = 0 THEN 'not_filled'"));
  assert.ok(mig.includes("was already closed as not filled (0 delivered)"));
});

test("driver not_done is accepted on a picked_up 0-filled row", () => {
  assert.ok(
    mig.includes(
      "AND NOT (p_outcome IN ('not_done','no_stock_on_truck') AND v_rd.filled_quantity = 0)",
    ),
  );
  assert.match(sqlTest, /driver_report_dispatch_outcome\(v_id, 'not_done'/);
});

test("amend void is accepted on a 0-filled row and credits nothing", () => {
  assert.ok(
    mig.includes(
      "OR (COALESCE(d.item_added, false) AND NOT (COALESCE(p_void, false) AND d.filled_quantity = 0))",
    ),
  );
  assert.match(mig, /IF d\.filled_quantity = 0 THEN[\s\S]*?'credited', 0/);
});

test("the driver page query excludes not_filled rows", () => {
  const q = driver.slice(
    driver.indexOf('.from("refill_dispatching")'),
    driver.indexOf("if (dispatchLines)"),
  );
  assert.ok(q.includes('.eq("picked_up", true)'));
  assert.ok(
    q.includes('.or("pack_outcome.is.null,pack_outcome.neq.not_filled")'),
  );
});

test("the warehouse return-ack queue excludes not_filled rows", () => {
  assert.ok(
    mig.includes(
      "(rd.pack_outcome IS DISTINCT FROM 'not_filled'::pack_outcome_enum) AND (COALESCE(rd.returned, false) = true)",
    ),
  );
});

test("the sweep is the one-time partial + 0-filled + undelivered rule since 1 Oct", () => {
  assert.match(
    mig,
    /SET pack_outcome = 'not_filled', include = false, not_filled_reason = 'sweep PRD-145'\s+WHERE dispatch_date >= DATE '2026-10-01'\s+AND pack_outcome = 'partial' AND filled_quantity = 0\s+AND driver_outcome IS NULL AND delivered_at IS NULL;/,
  );
});
