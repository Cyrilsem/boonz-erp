// PRD-072 WS-E gate: pushResultToToast renders v7 jsonb payloads correctly.
// Run: npx tsx scripts/prd072_toast_check.ts
import { pushResultToToast } from "../src/lib/dispatch-types";

const cases: [unknown, string | null, string][] = [
  [{ status: "ok", lines_pushed: 12, rpc_version: "v7_prd071_autopair_m2m" }, null, "✅ 12 lines pushed to dispatch"],
  [{ status: "ok", lines_pushed: 1 }, null, "✅ 1 line pushed to dispatch"],
  [{ status: "ok", lines_pushed: 0 }, null, "✅ 0 lines pushed to dispatch"],
  [{ status: "ok", lines_pushed: 5, lines_preserved_manual_edit: 2, m2m_transfer_pairs: 1 }, null, "✅ 5 lines pushed to dispatch (2 preserved, 1 M2M pair)"],
  [{ status: "error", error: "Machine not found: X" }, null, "⚠️ Push failed: Machine not found: X"],
  [{ status: "conservation_violation", reason: "SUM mismatch" }, null, "⛔ Push stopped: SUM mismatch"],
  [null, "network down", "⚠️ Push failed: network down"],
  [42, null, "⚠️ Push failed: no result from push_plan_to_dispatch"],
];
let fail = 0;
for (const [input, err, want] of cases) {
  const got = pushResultToToast(input, err);
  if (got !== want) { console.log("FAIL:", JSON.stringify(input), "->", got, "| want:", want); fail++; }
  else console.log("PASS:", got);
}
process.exit(fail ? 1 : 0);
