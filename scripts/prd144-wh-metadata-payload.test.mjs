#!/usr/bin/env node
/**
 * PRD-144 P0-4 regression - the adjust_warehouse_stock payload built by
 * adjustWarehouseLineMetadata (warehouse location / expiry edits).
 *
 *   node scripts/prd144-wh-metadata-payload.test.mjs
 *
 * The bug: the helper sent p_snapshot_date = null (the RPC then failed with
 * "null value in column snapshot_date violates not-null constraint") and no
 * new_consumer_stock (the RPC treats that as 0 and wipes packed stock).
 * The SQL half is supabase/tests/prd144_p0_4_adjust_warehouse_stock_payload.sql.
 */
import assert from "node:assert/strict";
import { test } from "node:test";

const { adjustWarehouseLineMetadata } = await import(
  new URL("../src/lib/inventory/adjust-warehouse-line.ts", import.meta.url).href
);

function fakeClient({ consumerStock = 7, rpcError = null } = {}) {
  const calls = [];
  return {
    calls,
    from(table) {
      assert.equal(table, "warehouse_inventory");
      return {
        select: () => ({
          eq: () => ({
            maybeSingle: async () => ({ data: { consumer_stock: consumerStock }, error: null }),
          }),
        }),
      };
    },
    async rpc(name, args) {
      calls.push({ name, args });
      return rpcError ? { data: null, error: rpcError } : { data: { status: "ok" }, error: null };
    },
  };
}

const base = {
  warehouseId: "wh-1",
  line: { wh_inventory_id: "inv-1", boonz_product_id: "bp-1", wh_location: "D08" },
  currentWarehouseStock: 12,
  currentStatus: "Active",
  reason: "inline_location_edit",
};

test("passes the current consumer stock and a real Dubai snapshot date", async () => {
  const c = fakeClient();
  const r = await adjustWarehouseLineMetadata(c, { ...base, currentConsumerStock: 5 });
  assert.equal(r.ok, true);
  const { name, args } = c.calls[0];
  assert.equal(name, "adjust_warehouse_stock");
  assert.match(args.p_snapshot_date, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(args.p_lines[0].new_consumer_stock, 5);
  assert.equal(args.p_lines[0].new_warehouse_stock, 12);
  assert.equal(args.p_lines[0].wh_location, "D08");
});

test("reads the live consumer stock when the caller does not have it", async () => {
  const c = fakeClient({ consumerStock: 7 });
  await adjustWarehouseLineMetadata(c, base);
  assert.equal(c.calls[0].args.p_lines[0].new_consumer_stock, 7);
  assert.notEqual(c.calls[0].args.p_snapshot_date, null);
});

test("returns the server error text", async () => {
  const c = fakeClient({ rpcError: { message: "adjust_warehouse_stock: forbidden for role field_staff" } });
  const r = await adjustWarehouseLineMetadata(c, { ...base, currentConsumerStock: 0 });
  assert.equal(r.ok, false);
  assert.equal(r.error, "adjust_warehouse_stock: forbidden for role field_staff");
});
