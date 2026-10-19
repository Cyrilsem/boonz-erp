#!/usr/bin/env node
/**
 * PRD-144 P0-1 - browser check of the request the pack screen builds for a
 * multi-lot product. Read-only against prod data:
 *   - every write RPC is aborted, and pack_dispatch_line is answered with a mock;
 *   - the dispatch read is pointed at a past packed date and one line is shown
 *     unpacked in the browser only, so there is something to tap.
 *
 *   BASE=http://localhost:3144 node scripts/prd144-pack-multilot.e2e.mjs \
 *     <machine_id> <past_date> <dispatch_id> <product text> <planned qty> <first lot id>
 *
 * Asserts: a pack_dispatch_line request is sent, picks are FEFO by lot, no 0-qty
 * pick, total = planned, the first pick is the earliest lot.
 */
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const BASE = process.env.BASE ?? "http://localhost:3144";
const [machineId, pastDate, dispatchId, productText, planned, firstLot] = process.argv.slice(2);
const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dubai" }).format(new Date());
const WRITE = /pack|confirm|skip|update|insert|write|set_|edit|add_|remove|delete|approve|receive|return|mark|unpick|pick_/i;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 420, height: 900 } });
const sent = [];
const aborted = [];

await page.goto(`${BASE}/login`);
await page.fill('input[type="email"]', "warehouse@boonz.test");
await page.fill('input[type="password"]', "Test1234!");
await page.click('button[type="submit"]');
await page.waitForURL((u) => !u.toString().includes("/login"), { timeout: 60000 });

await page.route("**/rest/v1/**", async (route) => {
  const req = route.request();
  const url = req.url();
  if (url.includes("/rpc/pack_dispatch_line")) {
    sent.push(JSON.parse(req.postData() ?? "{}"));
    return route.fulfill({ status: 200, contentType: "application/json", body: '{"status":"ok"}' });
  }
  if (!["GET", "HEAD"].includes(req.method())) {
    const name = url.split("/rest/v1/")[1].split("?")[0];
    if (!name.startsWith("rpc/") || WRITE.test(name)) {
      aborted.push(`${req.method()} ${name}`);
      return route.abort();
    }
    return route.continue();
  }
  const moved = url.replaceAll(`eq.${today}`, `eq.${pastDate}`);
  if (!url.includes("/rest/v1/refill_dispatching")) return route.continue({ url: moved });
  const resp = await route.fetch({ url: moved });
  let body = await resp.json();
  if (Array.isArray(body)) {
    body = body.map((r) =>
      r.dispatch_id === dispatchId
        ? { ...r, packed: false, pack_outcome: null, filled_quantity: null, dispatched: false, picked_up: false }
        : r,
    );
  }
  return route.fulfill({ response: resp, json: body });
});

await page.goto(`${BASE}/field/packing/${machineId}`, { waitUntil: "domcontentloaded" });
await page.getByText(productText, { exact: false }).first().waitFor({ timeout: 90000 });
await page.waitForTimeout(4000);
if (process.env.SHOT) {
  await page.screenshot({ path: process.env.SHOT, fullPage: true });
  console.log((await page.locator("body").innerText()).slice(0, 3000));
}
const card = page.locator(`#pack-card-${dispatchId}`);
console.log("card:", (await card.innerText()).replace(/\s+/g, " ").slice(0, 400));
await card.getByRole("button", { name: "✓ Packed" }).click();
await page.waitForTimeout(4000);
const toast = await page.locator('[role="alert"]').allInnerTexts();
await browser.close();

const fails = [];
const req = sent.find((b) => b.p_dispatch_id === dispatchId);
if (!req) fails.push(`no pack_dispatch_line request for ${dispatchId} (sent ${sent.length})`);
const picks = req?.p_picks ?? [];
if (picks.some((p) => !(p.qty > 0))) fails.push("a pick has qty <= 0");
const total = picks.reduce((s, p) => s + p.qty, 0);
if (req && total !== Number(planned)) fails.push(`picks total ${total} != planned ${planned}`);
if (req && picks[0]?.wh_inventory_id !== firstLot) fails.push(`first pick ${picks[0]?.wh_inventory_id} is not the earliest lot ${firstLot}`);
console.log(JSON.stringify({ picks, aborted, toast }, null, 1));
console.log(fails.length ? `RED\n- ${fails.join("\n- ")}` : "GREEN");
process.exit(fails.length ? 1 : 0);
