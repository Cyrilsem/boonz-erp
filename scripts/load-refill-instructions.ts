/**
 * scripts/load-refill-instructions.ts
 *
 * Loads refill_instructions.csv into the Supabase refill_instructions table.
 * - Deletes rows with report_timestamp >= '2026-03-31' first
 * - Resolves machine_id from machines.official_name
 * - Resolves shelf_id from shelf_configurations JOIN machines
 * - Batches inserts in chunks of 25
 *
 * Run: npx tsx scripts/load-refill-instructions.ts
 */

import fs from "fs";
import path from "path";
import { parse } from "csv-parse/sync";
import { createClient } from "@supabase/supabase-js";

// ── Config ────────────────────────────────────────────────────────────────────

const SUPABASE_URL = "https://eizcexopcuoycuosittm.supabase.co";
const SERVICE_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVpemNleG9wY3VveWN1b3NpdHRtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MzIyOTQ3NiwiZXhwIjoyMDg4ODA1NDc2fQ.q37vg0kV8m9VxgPjHLIanHD7jBSv9NYPmCnCAlQfauY";

const CSV_PATH =
  "/Users/cyrilsemaan/Documents/Boonz Script and Data/boonz 2.0 (marco)/boonz/output/refill_instructions.csv";

const CHUNK_SIZE = 25;
const DELETE_FROM_DATE = "2026-03-31";

// ── Helpers ───────────────────────────────────────────────────────────────────

function n(val: string): number | null {
  const trimmed = val?.trim();
  if (!trimmed || trimmed === "" || trimmed === "None") return null;
  const parsed = parseFloat(trimmed);
  return isNaN(parsed) ? null : parsed;
}

function i(val: string): number | null {
  const trimmed = val?.trim();
  if (!trimmed || trimmed === "" || trimmed === "None") return null;
  const parsed = parseInt(trimmed, 10);
  return isNaN(parsed) ? null : parsed;
}

function t(val: string): string | null {
  const trimmed = val?.trim();
  return trimmed && trimmed !== "" && trimmed !== "None" ? trimmed : null;
}

function chunks<T>(arr: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let j = 0; j < arr.length; j += size) {
    result.push(arr.slice(j, j + size));
  }
  return result;
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

  // 1. Parse CSV
  console.log("Reading CSV…");
  const raw = fs.readFileSync(CSV_PATH, "utf-8");
  const records = parse(raw, {
    columns: true,
    skip_empty_lines: true,
    trim: true,
  }) as Record<string, string>[];
  console.log(`  → ${records.length} rows parsed`);

  // 2. Delete existing rows for this report date
  console.log(`Deleting rows with report_timestamp >= '${DELETE_FROM_DATE}'…`);
  const { error: delError } = await supabase
    .from("refill_instructions")
    .delete()
    .gte("report_timestamp", DELETE_FROM_DATE);

  if (delError) {
    console.error("Delete failed:", delError.message);
    process.exit(1);
  }
  console.log(`  → Deleted existing rows for ${DELETE_FROM_DATE}+`);

  // 3. Build machine_id cache
  console.log("Building machine lookup…");
  const { data: machines, error: machErr } = await supabase
    .from("machines")
    .select("machine_id, official_name")
    .limit(10000);
  if (machErr) {
    console.error("Failed to fetch machines:", machErr.message);
    process.exit(1);
  }
  const machineMap = new Map<string, string>(
    (machines ?? []).map((m) => [
      m.official_name as string,
      m.machine_id as string,
    ]),
  );
  console.log(`  → ${machineMap.size} machines loaded`);

  // 4. Build shelf_id cache: key = "official_name|shelf_code"
  console.log("Building shelf lookup…");
  const { data: shelves, error: shelfErr } = await supabase
    .from("shelf_configurations")
    .select("shelf_id, shelf_code, machine_id")
    .limit(10000);
  if (shelfErr) {
    console.error("Failed to fetch shelf_configurations:", shelfErr.message);
    process.exit(1);
  }

  // Build reverse map: machine_id → official_name
  const machineIdToName = new Map<string, string>(
    (machines ?? []).map((m) => [
      m.machine_id as string,
      m.official_name as string,
    ]),
  );

  const shelfMap = new Map<string, string>();
  for (const s of shelves ?? []) {
    const machineName = machineIdToName.get(s.machine_id as string);
    if (machineName) {
      shelfMap.set(`${machineName}|${s.shelf_code}`, s.shelf_id as string);
    }
  }
  console.log(`  → ${shelfMap.size} shelf entries loaded`);

  // 5. Map rows
  console.log("Mapping rows…");
  let skipped = 0;
  const mapped: Record<string, unknown>[] = [];

  for (const r of records) {
    const machineName = r["Machine Name"]?.trim();
    const slotName = r["Slot name"]?.trim();

    const machine_id = machineMap.get(machineName ?? "");
    if (!machine_id) {
      console.warn(`  ⚠ Unknown machine: "${machineName}" — skipping row`);
      skipped++;
      continue;
    }

    // shelf_id: match by slot name as shelf_code
    const shelf_id = slotName
      ? (shelfMap.get(`${machineName}|${slotName}`) ?? null)
      : null;

    mapped.push({
      machine_id,
      shelf_id: shelf_id ?? null,
      slot_name: t(slotName ?? ""),
      pod_product_name: t(r["Product Name"]),
      report_timestamp: t(r["Report_Timestamp"]),
      current_stock: n(r["Current stock"]),
      max_stock: n(r["Max stock"]),
      target_stock: n(r["Target_stock"]),
      refill_qty: n(r["Refill_qty"]),
      refill_qty_positive: n(r["Refill_qty_positive"]),
      refill_reason: t(r["Refill_reason"]),
      machine_health_status: t(r["Machine_Health_Status"]),
      machine_strategy: t(r["Machine_Strategy"]),
      machine_reason: t(r["Machine_Reason"]),
      global_product_status: t(r["Global_Product_Status"]),
      global_product_strategy: t(r["Global_Product_Strategy"]),
      global_product_reason: t(r["Global_Product_Reason"]),
      local_performance_role: t(r["Local_Performance_Role"]),
      local_product_strategy: t(r["Local_Product_Strategy"]),
      local_product_reason: t(r["Local_Product_Reason"]),
      machine_avg_daily: n(r["Machine_avg_daily"]),
      machine_performance_score: n(r["Machine_performance_score"]),
      machine_trend_score: n(r["Machine_trend_score"]),
      product_base_score: n(r["Product_Base_Score"]),
      product_trend_score: n(r["Product_Trend_Score"]),
      units_sold_7d: n(r["Units_sold_7d"]),
      units_sold_15d: n(r["Units_sold_15d"]),
      machine_units_sold_30d: n(r["Machine_units_sold_30d"]),
      machine_daily_30d: n(r["Machine_daily_30d"]),
      machine_units_sold_60d: n(r["Machine_units_sold_60d"]),
      machine_daily_60d: n(r["Machine_daily_60d"]),
      machine_units_sold_90d: n(r["Machine_units_sold_90d"]),
      machine_days_active: i(r["Machine_days_active"]),
      suggested_product: t(r["Suggested_product"]),
      substitution_reason: t(r["Substitution_reason"]),
      strategy: t(r["Strategy"]),
      action_code: t(r["Action_Code"]),
      days_since_last_change: i(r["Days_Since_Last_Change"]),
      actual_selling_price: n(r["Actual_selling_price"]),
      recommended_selling_price: n(r["Recommended_selling_price"]),
      price_action: t(r["Price_Action"]),
      target_price: n(r["Target_Price"]),
      replenishment_product: t(r["Replenishment_Product"]),
      replenishment_reason: t(r["Replenishment_Reason"]),
      purge_price_action: t(r["Purge_Price_Action"]),
    });
  }

  console.log(
    `  → ${mapped.length} rows ready, ${skipped} skipped (unknown machines)`,
  );

  // 6. Batch insert
  const batches = chunks(mapped, CHUNK_SIZE);
  console.log(`Inserting ${batches.length} chunks of ${CHUNK_SIZE}…`);
  let inserted = 0;
  let errors = 0;

  for (let idx = 0; idx < batches.length; idx++) {
    const batch = batches[idx];
    const { error } = await supabase.from("refill_instructions").insert(batch);
    if (error) {
      console.error(
        `  ✗ Chunk ${idx + 1}/${batches.length} failed: ${error.message}`,
      );
      errors++;
    } else {
      inserted += batch.length;
      console.log(
        `  ✓ Inserted chunk ${idx + 1}/${batches.length} (${inserted} rows so far)`,
      );
    }
  }

  console.log(
    `\nDone. ${inserted} rows inserted, ${errors} chunks failed, ${skipped} rows skipped.`,
  );
  if (errors > 0) process.exit(1);
}

main().catch((e) => {
  console.error("Fatal:", e);
  process.exit(1);
});
