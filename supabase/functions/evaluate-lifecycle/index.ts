import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// ─────────────────────────────────────────────────────────────────────────
// evaluate-lifecycle  v14 (PRD-026 scoring integrity)
//
// Changes vs v13.1:
//   P1. sales_history fetch is PAGINATED (.range loop, ordered) — the old
//       single .limit(10000) silently truncated (62d window held 10,219
//       rows on 2026-06-12 and grows weekly; no ORDER BY, so WHICH rows
//       dropped was arbitrary). Hard assertion: refuses to score if the
//       page loop exceeds SALES_MAX_PAGES rather than scoring on
//       possibly-truncated sales. Response reports sales_rows_fetched.
//   P3. Trend guard in getSignalV2: strong absolute sellers can no longer
//       be condemned by a flat trend alone.
//         score >= 8 AND trend < 4 → KEEP  (was WIND DOWN; PRD-026 offered
//                                          PLATEAU-or-KEEP — KEEP chosen so
//                                          downstream signal lists need no
//                                          new enum value)
//         score >= 6 AND trend < 4 → WATCH (was WIND DOWN)
//         score >= 4 AND trend < 4 → WIND DOWN (unchanged)
//   P2. Absolute velocity floor applied to SLOT signals after relative
//       scoring (thresholds PROPOSED in PRD-026 §4, pending CS confirm):
//         DEAD requires literal zero sales in 30d (aligns w/ ENGINE ADD).
//         v30 >= 0.5/day (15+ u/mo): never ROTATE OUT or DEAD.
//         v30 >= 1.0/day (30+ u/mo): never worse than WATCH.
//       Relative ranking still drives placement; it stops condemning slots
//       that cover their shelf rent (Aquafina 36u/30d was DEAD — SWAP NOW).
//
// Changes vs v12 (carried from v13/v13.1):
//   1. STAR signal — score ≥ 9 AND fleet_vel_ratio ≥ 5  (new top tier)
//      Captures absolute fleet leaders that growth-only signals (DOUBLE
//      DOWN) miss because they're saturated and trend reads flat.
//   2. machines SELECT now pulls `relaunched_at`. When set, it overrides
//      first_sale_at as the RAMPING anchor — used when a machine is
//      physically relocated to a new venue.
//   3. isRampingMachine() reads relaunched_at first.
//   4. scorableSlots no longer silently drops machines with NULL
//      location_type. They get scored with an 'office' fallback; the
//      existing data-quality flag (UNNORMALIZED_LOCATION) still fires.
//   5. Per-slot signal call now passes fleetVelRatio (v30 / productAvg).
//      Product-level signal still uses default 1.0 — STAR doesn't apply
//      to global product scores by definition.
//   6. (v13.1) Dark filter whitelists ramping machines so newly-relaunched
//      slots flip to RAMPING instead of leaving stale DEAD on slot_lifecycle.
//
// Article 9: edge function remains a wrapper. Scoring math unchanged;
//             only classification rules, pagination, and floors added.
// ─────────────────────────────────────────────────────────────────────────

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const VALID_LOCATION_TYPES = new Set([
  "office",
  "coworking",
  "entertainment",
  "warehouse",
]);
const FALLBACK_LOCATION_TYPE = "office";

const MACHINE_RAMP_DAYS = 30;
const PRODUCT_RAMP_DAYS = 30;
const EMA_ALPHA = 0.67;
const TREND_EMA_ALPHA = 0.4;
const TREND_MATURITY_FULL_DAYS = 60;

// STAR thresholds (E-1.1)
const STAR_SCORE_MIN = 9;
const STAR_FLEET_RATIO_MIN = 5.0;

// P1 (v14): paginated sales fetch — no silent truncation.
const SALES_PAGE_SIZE = 10000;
const SALES_MAX_PAGES = 30;

// P2 (v14): absolute velocity floors (units/day over 30d).
// PRD-026 §4 PROPOSED thresholds — CS sign-off pending as of 2026-06-12.
const VELOCITY_FLOOR_NEVER_NEG = 0.5; // 15+ u/mo: never ROTATE OUT / DEAD
const VELOCITY_FLOOR_WATCH_MIN = 1.0; // 30+ u/mo: never worse than WATCH

function getSignalV2(
  score: number,
  trend: number,
  fleetVelRatio: number = 1.0,
): string {
  if (score >= STAR_SCORE_MIN && fleetVelRatio >= STAR_FLEET_RATIO_MIN)
    return "STAR";
  if (score >= 8 && trend >= 7) return "DOUBLE DOWN";
  if (score >= 6 && trend >= 7) return "KEEP GROWING";
  if (score >= 4 && trend >= 4) return "KEEP";
  // P3 (v14): trend guard — absolute strength wins over a flat trend.
  if (score >= 8 && trend < 4) return "KEEP";
  if (score >= 6 && trend < 4) return "WATCH";
  if (score >= 4 && trend < 4) return "WIND DOWN";
  if (score >= 2 && trend >= 7) return "WATCH";
  if (score >= 2) return "WIND DOWN";
  if (score >= 1) return "ROTATE OUT";
  return "DEAD — SWAP NOW";
}

// P2 (v14): slot-level absolute velocity floor, applied after relative scoring.
// Severity order: WATCH < WIND DOWN < ROTATE OUT < DEAD — SWAP NOW.
function applyVelocityFloor(signal: string, v30: number): string {
  let s = signal;
  // DEAD requires literal zero sales over 30d (ENGINE ADD alignment).
  if (s === "DEAD — SWAP NOW" && v30 > 0) s = "ROTATE OUT";
  if (
    v30 >= VELOCITY_FLOOR_NEVER_NEG &&
    (s === "ROTATE OUT" || s === "DEAD — SWAP NOW")
  ) {
    s = "WIND DOWN";
  }
  if (
    v30 >= VELOCITY_FLOOR_WATCH_MIN &&
    (s === "WIND DOWN" || s === "ROTATE OUT" || s === "DEAD — SWAP NOW")
  ) {
    s = "WATCH";
  }
  return s;
}

type DailySales = Map<string, number>;

function velocityN(daily: DailySales, days: number): number {
  const cutoff = Date.now() - days * 86400000;
  let total = 0;
  for (const [d, q] of daily) {
    if (new Date(d).getTime() >= cutoff) total += q;
  }
  return total / days;
}

function trendV2(
  daily: DailySales,
  ageDays: number,
  priorTrend: number | null,
): number {
  const v7 = velocityN(daily, 7);
  const v14 = velocityN(daily, 14);
  const v30 = velocityN(daily, 30);
  const v60 = velocityN(daily, 60);

  let accel = 0;
  let decel = 0;
  if (v14 > 0 && v7 > v14 * 1.1) accel++;
  if (v14 > 0 && v7 < v14 * 0.9) decel++;
  if (v30 > 0 && v14 > v30 * 1.1) accel++;
  if (v30 > 0 && v14 < v30 * 0.9) decel++;
  if (v60 > 0 && v30 > v60 * 1.1) accel++;
  if (v60 > 0 && v30 < v60 * 0.9) decel++;

  const net = Math.max(-3, Math.min(3, accel - decel));
  const rawTrend = 5 + (net / 3) * 5;

  const maturity = Math.max(0, Math.min(1, ageDays / TREND_MATURITY_FULL_DAYS));
  const ceiling = 5 + 5 * maturity;
  const floor = 5 - 5 * maturity;
  const capped = Math.max(floor, Math.min(ceiling, rawTrend));

  if (priorTrend === null || isNaN(priorTrend)) return r2(capped);
  return r2(TREND_EMA_ALPHA * capped + (1 - TREND_EMA_ALPHA) * priorTrend);
}

function consistencyComponent(daily: DailySales): number {
  const cutoff = Date.now() - 30 * 86400000;
  const vals: number[] = [];
  for (const [d, q] of daily) {
    if (new Date(d).getTime() >= cutoff) vals.push(q);
  }
  if (vals.length === 0) return 0;
  const mean = vals.reduce((a, b) => a + b, 0) / vals.length;
  if (mean === 0) return 0;
  const variance = vals.reduce((s, v) => s + (v - mean) ** 2, 0) / vals.length;
  const cv = Math.sqrt(variance) / mean;
  return Math.min(10, Math.max(0, 10 - cv * 10));
}

function r2(n: number) {
  return Math.round(n * 100) / 100;
}

function clip01_10(n: number): number {
  return Math.max(0, Math.min(10, n));
}

function ema(today: number, prior: number | null): number {
  if (prior === null || isNaN(prior)) return r2(today);
  return r2(EMA_ALPHA * today + (1 - EMA_ALPHA) * prior);
}

function normalizeName(s: string | null | undefined): string {
  return (s ?? "").toLowerCase().trim().replace(/\s+/g, " ");
}

function padShelf(code: string | null | undefined): string {
  const m = /^([A-Z])(\d+)$/.exec(code ?? "");
  return m
    ? `${m[1]}${String(m[2]).padStart(2, "0")}`
    : (code ?? "").toUpperCase();
}

function effectiveLocationType(loc: string | null | undefined): string {
  if (loc && VALID_LOCATION_TYPES.has(loc)) return loc;
  return FALLBACK_LOCATION_TYPE;
}

Deno.serve(async (_req) => {
  const t0 = Date.now();
  try {
    const [
      machinesRes,
      snapshotsRes,
      shelfConfigsRes,
      podsRes,
      podInvRes,
      nameConvRes,
    ] = await Promise.all([
      supabase
        .from("machines")
        .select(
          "machine_id,official_name,location_type,include_in_refill,created_at,relaunched_at",
        )
        .eq("include_in_refill", true)
        .limit(10000),
      supabase
        .from("weimi_aisle_snapshots")
        .select("machine_id,slot_code,product_name,current_stock,snapshot_at")
        .order("snapshot_at", { ascending: false })
        .limit(20000),
      supabase
        .from("shelf_configurations")
        .select("machine_id,shelf_id,shelf_code,is_phantom")
        .eq("is_phantom", false)
        .limit(10000),
      supabase
        .from("pod_products")
        .select("pod_product_id,pod_product_name,product_family_id")
        .limit(10000),
      supabase
        .from("pod_inventory")
        .select("machine_id,shelf_id,current_stock,status")
        .limit(10000),
      supabase
        .from("product_name_conventions")
        .select("original_name,official_name")
        .limit(10000),
    ]);

    // P1 (v14): paginated sales fetch — the 62d window exceeds any single
    // PostgREST page. Ordered so pages are deterministic; loud failure
    // instead of silent truncation.
    const sales: Array<{
      machine_id: string;
      pod_product_name: string;
      qty: number;
      transaction_date: string;
    }> = [];
    let salesPages = 0;
    {
      const since = new Date(Date.now() - 62 * 86400000).toISOString();
      for (;;) {
        const { data, error } = await supabase
          .from("sales_history")
          .select("machine_id,pod_product_name,qty,transaction_date")
          .eq("delivery_status", "Successful")
          .gte("transaction_date", since)
          .order("transaction_date", { ascending: true })
          .order("transaction_id", { ascending: true })
          .range(
            salesPages * SALES_PAGE_SIZE,
            (salesPages + 1) * SALES_PAGE_SIZE - 1,
          );
        if (error) {
          throw new Error(
            `sales_history page ${salesPages} fetch failed: ${error.message}`,
          );
        }
        sales.push(...(data ?? []));
        salesPages++;
        if ((data ?? []).length < SALES_PAGE_SIZE) break;
        if (salesPages >= SALES_MAX_PAGES) {
          throw new Error(
            `sales_history pagination exceeded ${SALES_MAX_PAGES} pages ` +
              `(${sales.length} rows) — refusing to score on possibly-truncated sales`,
          );
        }
      }
    }

    const firstSaleRes = await supabase
      .from("v_machine_first_sale")
      .select("machine_id,first_sale_at")
      .limit(10000);

    const productFirstSeenRes = await supabase
      .from("v_product_first_seen")
      .select("pod_product_id,first_seen_at")
      .limit(10000);

    const machines = machinesRes.data ?? [];
    const snapshots = snapshotsRes.data ?? [];
    const shelfConfigs = shelfConfigsRes.data ?? [];
    const pods = podsRes.data ?? [];
    const podInv = podInvRes.data ?? [];
    const nameConv = nameConvRes.data ?? [];
    const firstSales = firstSaleRes.data ?? [];
    const productFirstSeen = productFirstSeenRes.data ?? [];

    const machineMap = new Map(machines.map((m) => [m.machine_id, m]));
    const podByName = new Map(
      pods.map((p) => [normalizeName(p.pod_product_name), p.pod_product_id]),
    );
    const nameAlias = new Map(
      nameConv.map((n) => [
        normalizeName(n.original_name ?? ""),
        normalizeName(n.official_name ?? ""),
      ]),
    );
    const resolvePodId = (name: string): string | null => {
      const k = normalizeName(name);
      return podByName.get(k) ?? podByName.get(nameAlias.get(k) ?? "") ?? null;
    };

    const shelfIdMap = new Map<string, string>();
    for (const sc of shelfConfigs) {
      if (sc.machine_id && sc.shelf_code) {
        shelfIdMap.set(`${sc.machine_id}:${sc.shelf_code}`, sc.shelf_id);
      }
    }

    const latestSnap = new Map<string, (typeof snapshots)[0]>();
    for (const s of snapshots) {
      const k = `${s.machine_id}:${s.slot_code}`;
      if (!latestSnap.has(k)) latestSnap.set(k, s);
    }

    type RealitySlot = {
      machine_id: string;
      shelf_id: string;
      shelf_code: string;
      pod_product_id: string;
    };
    const reality: RealitySlot[] = [];
    const dqUnresolvedShelf: Array<Record<string, unknown>> = [];
    const dqUnresolvedProduct: Array<Record<string, unknown>> = [];

    for (const snap of latestSnap.values()) {
      const shelf_code = padShelf(snap.slot_code);
      const shelf_id = shelfIdMap.get(`${snap.machine_id}:${shelf_code}`);
      if (!shelf_id) {
        dqUnresolvedShelf.push({
          flag_type: "UNRESOLVED_SHELF_ID",
          severity: "warning",
          scope: "machine",
          machine_id: snap.machine_id,
          message: `Snapshot slot_code=${snap.slot_code} (→ ${shelf_code}) has no shelf_configurations row.`,
        });
        continue;
      }
      const pid = resolvePodId(snap.product_name ?? "");
      if (!pid) {
        dqUnresolvedProduct.push({
          flag_type: "UNRESOLVED_POD_PRODUCT_NAME",
          severity: "warning",
          scope: "machine",
          machine_id: snap.machine_id,
          message: `Snapshot product_name "${snap.product_name}" at ${shelf_code} does not resolve to any pod_product_id.`,
        });
        continue;
      }
      reality.push({
        machine_id: snap.machine_id,
        shelf_id,
        shelf_code,
        pod_product_id: pid,
      });
    }

    const activeMachineIds = new Set(machines.map((m) => m.machine_id));
    const { data: ghostRows } = await supabase
      .from("slot_lifecycle")
      .select("machine_id,first_seen_at")
      .eq("archived", false)
      .limit(20000);
    const ghostMachineIds = Array.from(
      new Set(
        (ghostRows ?? [])
          .filter((r) => !activeMachineIds.has(r.machine_id))
          .map((r) => r.machine_id),
      ),
    );
    if (ghostMachineIds.length > 0) {
      await supabase
        .from("slot_lifecycle")
        .update({ archived: true, rotated_out_at: new Date().toISOString() })
        .in("machine_id", ghostMachineIds)
        .eq("archived", false);
    }

    const repurposeMap = new Map<string, Date>();
    const { data: repurposedMachines } = await supabase
      .from("machines")
      .select("machine_id,repurposed_at")
      .not("repurposed_at", "is", null)
      .limit(10000);
    for (const m of repurposedMachines ?? []) {
      if (m.machine_id && m.repurposed_at) {
        repurposeMap.set(m.machine_id, new Date(m.repurposed_at));
      }
    }
    const repurposeGhostIds: Array<{
      machine_id: string;
      first_seen_at: string;
    }> = [];
    for (const r of ghostRows ?? []) {
      const repDate = repurposeMap.get(r.machine_id);
      if (repDate && r.first_seen_at && new Date(r.first_seen_at) < repDate) {
        repurposeGhostIds.push({
          machine_id: r.machine_id,
          first_seen_at: r.first_seen_at,
        });
      }
    }
    if (repurposeGhostIds.length > 0) {
      const ghostMids = Array.from(
        new Set(repurposeGhostIds.map((g) => g.machine_id)),
      );
      for (const mid of ghostMids) {
        const cutoff = repurposeMap.get(mid)!.toISOString();
        await supabase
          .from("slot_lifecycle")
          .update({ archived: true, rotated_out_at: new Date().toISOString() })
          .eq("machine_id", mid)
          .eq("archived", false)
          .lt("first_seen_at", cutoff);
      }
    }

    const firstSaleByMachine = new Map<string, Date>();
    for (const r of firstSales) {
      if (r.machine_id && r.first_sale_at) {
        firstSaleByMachine.set(r.machine_id, new Date(r.first_sale_at));
      }
    }

    const isRampingMachine = (machineId: string): boolean => {
      const m = machineMap.get(machineId);
      if (!m) return false;
      if (m.relaunched_at) {
        const days =
          (Date.now() - new Date(m.relaunched_at).getTime()) / 86400000;
        return days < MACHINE_RAMP_DAYS;
      }
      const firstSale = firstSaleByMachine.get(machineId);
      if (firstSale) {
        const days = (Date.now() - firstSale.getTime()) / 86400000;
        return days < MACHINE_RAMP_DAYS;
      }
      if (m.created_at) {
        const days = (Date.now() - new Date(m.created_at).getTime()) / 86400000;
        if (days < MACHINE_RAMP_DAYS) return true;
      }
      return false;
    };

    const firstSeenByProduct = new Map<string, Date>();
    for (const r of productFirstSeen) {
      if (r.pod_product_id && r.first_seen_at) {
        firstSeenByProduct.set(r.pod_product_id, new Date(r.first_seen_at));
      }
    }
    const isRampingProduct = (pid: string): boolean => {
      const fs = firstSeenByProduct.get(pid);
      if (!fs) return true;
      const days = (Date.now() - fs.getTime()) / 86400000;
      return days < PRODUCT_RAMP_DAYS;
    };

    const cut14 = Date.now() - 14 * 86400000;
    const activeMachines = new Set(
      sales
        .filter((s) => new Date(s.transaction_date).getTime() > cut14)
        .map((s) => s.machine_id),
    );
    const darkMachines = new Set(
      machines
        .filter((m) => !activeMachines.has(m.machine_id))
        .map((m) => m.machine_id),
    );

    const [existingSlotsRes, existingProductsRes] = await Promise.all([
      supabase
        .from("slot_lifecycle")
        .select(
          "machine_id,shelf_id,pod_product_id,score,trend_component,first_seen_at,is_current",
        )
        .eq("archived", false)
        .limit(20000),
      supabase
        .from("product_lifecycle_global")
        .select("pod_product_id,score,trend_component")
        .limit(10000),
    ]);

    const existingSlots = existingSlotsRes.data ?? [];
    const existingByLedger = new Map(
      existingSlots.map((s) => [
        `${s.machine_id}:${s.shelf_id}:${s.pod_product_id}`,
        s,
      ]),
    );
    const currentByLocator = new Map<string, string>();
    for (const s of existingSlots) {
      if (s.is_current)
        currentByLocator.set(`${s.machine_id}:${s.shelf_id}`, s.pod_product_id);
    }
    const newByLocator = new Map<string, string>();
    for (const r of reality) {
      newByLocator.set(`${r.machine_id}:${r.shelf_id}`, r.pod_product_id);
    }
    const existingProductScores = new Map<string, number>(
      (existingProductsRes.data ?? []).map((p) => [
        p.pod_product_id,
        Number(p.score),
      ]),
    );
    const existingProductTrends = new Map<string, number>(
      (existingProductsRes.data ?? [])
        .filter((p) => p.trend_component !== null)
        .map((p) => [p.pod_product_id, Number(p.trend_component)]),
    );

    const disc = {
      new_machines: 0,
      new_slots: 0,
      new_products: 0,
      new_families: 0,
      archived_slots: 0,
      rotations: 0,
    };

    const nowIso = new Date().toISOString();

    const rotationsToClose: Array<{
      machine_id: string;
      shelf_id: string;
      pod_product_id: string;
    }> = [];
    for (const [locator, oldPid] of currentByLocator) {
      const newPid = newByLocator.get(locator);
      if (newPid && newPid !== oldPid) {
        const [machine_id, shelf_id] = locator.split(":");
        rotationsToClose.push({ machine_id, shelf_id, pod_product_id: oldPid });
      }
    }
    for (const r of rotationsToClose) {
      await supabase
        .from("slot_lifecycle")
        .update({ is_current: false, rotated_out_at: nowIso })
        .eq("machine_id", r.machine_id)
        .eq("shelf_id", r.shelf_id)
        .eq("pod_product_id", r.pod_product_id);
    }
    disc.rotations = rotationsToClose.length;

    const stillConfiguredShelfIds = new Set(
      shelfConfigs.map((sc) => sc.shelf_id),
    );
    const toArchive = existingSlots.filter(
      (s) => s.is_current && !stillConfiguredShelfIds.has(s.shelf_id),
    );
    for (const s of toArchive) {
      await supabase
        .from("slot_lifecycle")
        .update({ archived: true, rotated_out_at: nowIso })
        .eq("machine_id", s.machine_id)
        .eq("shelf_id", s.shelf_id)
        .eq("pod_product_id", s.pod_product_id);
    }
    disc.archived_slots = toArchive.length;

    const existingProdIds = new Set(existingProductScores.keys());
    const newProdRows = pods.filter(
      (p) => !existingProdIds.has(p.pod_product_id),
    );
    disc.new_products = newProdRows.length;
    for (let i = 0; i < newProdRows.length; i += 100) {
      await supabase.from("product_lifecycle_global").upsert(
        newProdRows.slice(i, i + 100).map((p) => ({
          pod_product_id: p.pod_product_id,
          score: 5.0,
          signal: "KEEP",
        })),
        { onConflict: "pod_product_id" },
      );
    }

    await supabase
      .from("lifecycle_data_quality_flags")
      .update({ resolved_at: nowIso })
      .in("flag_type", [
        "MACHINE_DARK",
        "UNNORMALIZED_LOCATION",
        "UNRESOLVED_SHELF_ID",
        "UNRESOLVED_POD_PRODUCT_NAME",
        "MACHINE_RAMPING",
      ])
      .is("resolved_at", null);

    const dqFlags: Array<{
      flag_type: string;
      severity: string;
      scope: string;
      machine_id?: string | null;
      shelf_id?: string | null;
      pod_product_id?: string | null;
      message: string;
    }> = [];

    for (const m of machines) {
      if (darkMachines.has(m.machine_id) && !isRampingMachine(m.machine_id)) {
        dqFlags.push({
          flag_type: "MACHINE_DARK",
          severity: "critical",
          scope: "machine",
          machine_id: m.machine_id,
          message: `${m.official_name} has 0 successful sales in last 14 days`,
        });
      }
      if (!m.location_type || !VALID_LOCATION_TYPES.has(m.location_type)) {
        dqFlags.push({
          flag_type: "UNNORMALIZED_LOCATION",
          severity: "warning",
          scope: "machine",
          machine_id: m.machine_id,
          message: `location_type '${m.location_type}' is null or unnormalized — scoring with '${FALLBACK_LOCATION_TYPE}' fallback`,
        });
      }
      if (isRampingMachine(m.machine_id)) {
        const relaunched = m.relaunched_at ? new Date(m.relaunched_at) : null;
        const firstSale = firstSaleByMachine.get(m.machine_id);
        const anchor = relaunched ?? firstSale ?? null;
        const anchorLabel = relaunched
          ? "relaunch"
          : firstSale
            ? "first sale"
            : "deployment";
        const daysSinceAnchor = anchor
          ? Math.floor((Date.now() - anchor.getTime()) / 86400000)
          : m.created_at
            ? Math.floor(
                (Date.now() - new Date(m.created_at).getTime()) / 86400000,
              )
            : null;
        dqFlags.push({
          flag_type: "MACHINE_RAMPING",
          severity: "info",
          scope: "machine",
          machine_id: m.machine_id,
          message: `${m.official_name} ramping — ${daysSinceAnchor ?? "?"}/${MACHINE_RAMP_DAYS}d since ${anchorLabel}. Lifecycle signal capped at RAMPING.`,
        });
      }
    }

    const allMachineDq = [
      ...dqFlags,
      ...dqUnresolvedShelf,
      ...dqUnresolvedProduct,
    ];
    for (let i = 0; i < allMachineDq.length; i += 25) {
      await supabase
        .from("lifecycle_data_quality_flags")
        .insert(allMachineDq.slice(i, i + 25));
    }

    const salesMap = new Map<string, DailySales>();
    const productSalesMap = new Map<string, DailySales>();
    for (const s of sales) {
      const pid = resolvePodId(s.pod_product_name);
      if (!pid) continue;
      const d = s.transaction_date.substring(0, 10);
      const qty = Number(s.qty);
      const k = `${s.machine_id}:${pid}`;
      if (!salesMap.has(k)) salesMap.set(k, new Map());
      const ds = salesMap.get(k)!;
      ds.set(d, (ds.get(d) ?? 0) + qty);
      if (!productSalesMap.has(pid)) productSalesMap.set(pid, new Map());
      const pds = productSalesMap.get(pid)!;
      pds.set(d, (pds.get(d) ?? 0) + qty);
    }

    // (E-1.5) — null-location-type machines no longer silently dropped.
    // Dark machines (no sales in 14d) are excluded from scoring EXCEPT
    // when ramping (just relaunched / brand new) — those slots need to
    // pass through scoring so the RAMPING override fires; otherwise their
    // existing slot_lifecycle rows keep stale DEAD signals.
    const scorableSlots = reality.filter(
      (r) => !darkMachines.has(r.machine_id) || isRampingMachine(r.machine_id),
    );

    type VData = {
      v7: number;
      v14: number;
      v30: number;
      cons: number;
      daily: DailySales;
    };
    const vMap = new Map<string, VData>();
    for (const slot of scorableSlots) {
      const daily =
        salesMap.get(`${slot.machine_id}:${slot.pod_product_id}`) ?? new Map();
      vMap.set(`${slot.machine_id}:${slot.shelf_id}:${slot.pod_product_id}`, {
        v7: velocityN(daily, 7),
        v14: velocityN(daily, 14),
        v30: velocityN(daily, 30),
        cons: consistencyComponent(daily),
        daily,
      });
    }

    type ProductAgg = {
      total_v30: number;
      slot_count: number;
      machine_set: Set<string>;
      ramping_machine_set: Set<string>;
      best_loc: Map<string, number[]>;
    };
    const productAgg = new Map<string, ProductAgg>();
    for (const slot of scorableSlots) {
      const v = vMap.get(
        `${slot.machine_id}:${slot.shelf_id}:${slot.pod_product_id}`,
      );
      if (!v) continue;
      const m = machineMap.get(slot.machine_id);
      const locType = effectiveLocationType(m?.location_type);
      let agg = productAgg.get(slot.pod_product_id);
      if (!agg) {
        agg = {
          total_v30: 0,
          slot_count: 0,
          machine_set: new Set(),
          ramping_machine_set: new Set(),
          best_loc: new Map(),
        };
        productAgg.set(slot.pod_product_id, agg);
      }
      agg.total_v30 += v.v30;
      agg.slot_count += 1;
      agg.machine_set.add(slot.machine_id);
      if (isRampingMachine(slot.machine_id))
        agg.ramping_machine_set.add(slot.machine_id);
      if (!agg.best_loc.has(locType)) agg.best_loc.set(locType, []);
    }

    const productPerSlotAvg = new Map<string, number>();
    const productPerMachineAvg = new Map<string, number>();
    for (const [pid, agg] of productAgg) {
      const slotCount = agg.slot_count;
      const machineCount = agg.machine_set.size;
      productPerSlotAvg.set(pid, slotCount > 0 ? agg.total_v30 / slotCount : 0);
      productPerMachineAvg.set(
        pid,
        machineCount > 0 ? agg.total_v30 / machineCount : 0,
      );
    }

    const productEntriesSorted = [...productPerSlotAvg.entries()].sort(
      (a, b) => b[1] - a[1],
    );
    const N = productEntriesSorted.length;
    const productGlobalRank = new Map<string, number>();
    const productGlobalRawScore = new Map<string, number>();
    productEntriesSorted.forEach(([pid, _avg], idx) => {
      const rank = idx + 1;
      productGlobalRank.set(pid, rank);
      const raw = N > 1 ? (1 - (rank - 1) / (N - 1)) * 10 : 5.0;
      productGlobalRawScore.set(pid, raw);
    });

    const today = new Date().toISOString().split("T")[0];
    const slotUpdates: Record<string, unknown>[] = [];
    const slotHistory: Record<string, unknown>[] = [];
    const slotDqFlags: typeof dqFlags = [];

    let slotsEval = 0;
    const slotScoreDelta = { up: 0, down: 0 };

    for (const slot of scorableSlots) {
      const m = machineMap.get(slot.machine_id)!;
      const ledgerKey = `${slot.machine_id}:${slot.shelf_id}:${slot.pod_product_id}`;
      const v = vMap.get(ledgerKey)!;

      const productAvg = productPerSlotAvg.get(slot.pod_product_id) ?? 0;

      let spectrum_ratio: number;
      if (v.v30 <= 0) {
        spectrum_ratio = 0;
      } else if (productAvg <= 0) {
        spectrum_ratio = 2;
      } else {
        spectrum_ratio = v.v30 / productAvg;
      }
      let local_score_raw = clip01_10(spectrum_ratio * 5);

      const existingSlot = existingByLedger.get(ledgerKey);
      const firstSeen = existingSlot?.first_seen_at ?? new Date().toISOString();
      const ageD = Math.floor(
        (Date.now() - new Date(firstSeen).getTime()) / 86400000,
      );

      if (ageD < 14) {
        local_score_raw = Math.min(local_score_raw, 4.5);
        slotDqFlags.push({
          flag_type: "INSUFFICIENT_DATA",
          severity: "info",
          scope: "slot",
          machine_id: slot.machine_id,
          shelf_id: slot.shelf_id,
          message: `Slot age ${ageD}d < 14 days — score capped at TRIAL`,
        });
      }

      if (v.v30 > 50) {
        slotDqFlags.push({
          flag_type: "VELOCITY_OUTLIER",
          severity: "warning",
          scope: "slot",
          machine_id: slot.machine_id,
          shelf_id: slot.shelf_id,
          message: `Velocity ${v.v30.toFixed(1)} units/day exceeds 50 — possible data error`,
        });
      }

      const priorScore = existingSlot?.score
        ? Number(existingSlot.score)
        : null;
      const score = ema(local_score_raw, priorScore);

      if (priorScore !== null) {
        if (score - priorScore >= 0.5) slotScoreDelta.up++;
        else if (priorScore - score >= 0.5) slotScoreDelta.down++;
      }

      const priorSlotTrend =
        existingSlot?.trend_component != null
          ? Number(existingSlot.trend_component)
          : null;
      const tc = trendV2(v.daily, ageD, priorSlotTrend);

      const fleetVelRatio = productAvg > 0 ? v.v30 / productAvg : 1.0;

      // P2 (v14): relative signal, then absolute velocity floor.
      const rawSignal = applyVelocityFloor(
        getSignalV2(score, tc, fleetVelRatio),
        v.v30,
      );
      const signal =
        isRampingMachine(slot.machine_id) ||
        isRampingProduct(slot.pod_product_id)
          ? "RAMPING"
          : rawSignal;

      slotUpdates.push({
        machine_id: slot.machine_id,
        shelf_id: slot.shelf_id,
        shelf_code: slot.shelf_code ?? "",
        pod_product_id: slot.pod_product_id,
        score,
        local_score_raw: r2(local_score_raw),
        spectrum_ratio: r2(spectrum_ratio),
        product_avg_v30_at_score_time: r2(productAvg),
        previous_score: priorScore,
        velocity_component: r2(local_score_raw),
        trend_component: r2(tc),
        consistency_component: r2(v.cons),
        velocity_7d: r2(v.v7),
        velocity_14d: r2(v.v14),
        velocity_30d: r2(v.v30),
        archetype_baseline_velocity: r2(productAvg),
        signal,
        slot_age_days: ageD,
        last_evaluated_at: nowIso,
        is_current: true,
        rotated_in_at: nowIso,
      });

      slotHistory.push({
        scope: "slot",
        machine_id: slot.machine_id,
        shelf_id: slot.shelf_id,
        pod_product_id: slot.pod_product_id,
        snapshot_date: today,
        score,
        velocity_30d: r2(v.v30),
        score_kind: "v2_split_global_local",
      });

      slotsEval++;
    }

    for (let i = 0; i < slotUpdates.length; i += 100) {
      await supabase
        .from("slot_lifecycle")
        .upsert(slotUpdates.slice(i, i + 100), {
          onConflict: "machine_id,shelf_id,pod_product_id",
        });
    }

    for (let i = 0; i < slotHistory.length; i += 25) {
      await supabase
        .from("lifecycle_score_history")
        .insert(slotHistory.slice(i, i + 25));
    }

    for (let i = 0; i < slotDqFlags.length; i += 25) {
      await supabase
        .from("lifecycle_data_quality_flags")
        .insert(slotDqFlags.slice(i, i + 25));
    }

    const prodUpdates: Record<string, unknown>[] = [];
    const prodHistory: Record<string, unknown>[] = [];

    for (const pod of pods) {
      const agg = productAgg.get(pod.pod_product_id);
      const perMachineAvg = productPerMachineAvg.get(pod.pod_product_id) ?? 0;
      const perSlotAvg = productPerSlotAvg.get(pod.pod_product_id) ?? 0;
      const rawScore = productGlobalRawScore.get(pod.pod_product_id) ?? 0;
      const rank = productGlobalRank.get(pod.pod_product_id) ?? null;
      const totalV30 = agg ? r2(agg.total_v30) : 0;
      const slotCount = agg ? agg.slot_count : 0;
      const machineCount = agg ? agg.machine_set.size : 0;
      const rampingCount = agg ? agg.ramping_machine_set.size : 0;
      const productDaily = productSalesMap.get(pod.pod_product_id);
      const fs = firstSeenByProduct.get(pod.pod_product_id);
      const productAgeD = fs ? (Date.now() - fs.getTime()) / 86400000 : 0;
      const priorProductTrend =
        existingProductTrends.get(pod.pod_product_id) ?? null;
      const globalTrend = productDaily
        ? trendV2(productDaily, productAgeD, priorProductTrend)
        : 5.0;

      const priorScore = existingProductScores.get(pod.pod_product_id) ?? null;
      const score = ema(rawScore, priorScore);

      let bestLoc: string | null = null;
      let worstLoc: string | null = null;
      if (agg) {
        const locAvgs: [string, number][] = [];
        for (const [loc, scores] of agg.best_loc) {
          if (scores.length === 0) continue;
          const a = scores.reduce((s, x) => s + x, 0) / scores.length;
          locAvgs.push([loc, a]);
        }
        if (locAvgs.length) {
          locAvgs.sort((a, b) => b[1] - a[1]);
          bestLoc = locAvgs[0][0];
          worstLoc = locAvgs[locAvgs.length - 1][0];
        }
      }

      const rawProdSignal = getSignalV2(score, globalTrend);
      const signal = isRampingProduct(pod.pod_product_id)
        ? "RAMPING"
        : rawProdSignal;

      prodUpdates.push({
        pod_product_id: pod.pod_product_id,
        score,
        score_raw: r2(rawScore),
        global_rank: rank,
        per_machine_avg_v30: r2(perMachineAvg),
        per_slot_avg_v30: r2(perSlotAvg),
        slot_count: slotCount,
        ramping_machine_count: rampingCount,
        trend_component: globalTrend,
        machine_count: machineCount,
        total_velocity_30d: totalV30,
        signal,
        best_location_type: bestLoc,
        worst_location_type: worstLoc,
        last_evaluated_at: nowIso,
      });

      prodHistory.push({
        scope: "product",
        pod_product_id: pod.pod_product_id,
        snapshot_date: today,
        score,
        velocity_30d: totalV30,
        score_kind: "v2_split_global_local",
      });
    }

    for (let i = 0; i < prodUpdates.length; i += 100) {
      await supabase
        .from("product_lifecycle_global")
        .upsert(prodUpdates.slice(i, i + 100), {
          onConflict: "pod_product_id",
        });
    }
    for (let i = 0; i < prodHistory.length; i += 25) {
      await supabase
        .from("lifecycle_score_history")
        .insert(prodHistory.slice(i, i + 25));
    }

    const { data: families } = await supabase
      .from("product_families")
      .select("product_family_id")
      .limit(10000);
    const { data: updatedProdScores } = await supabase
      .from("product_lifecycle_global")
      .select("pod_product_id,score,total_velocity_30d")
      .limit(10000);
    const prodScoreMap = new Map(
      (updatedProdScores ?? []).map((p) => [p.pod_product_id, p]),
    );

    const familyMemberMap = new Map<string, string[]>();
    for (const pod of pods) {
      if (!pod.product_family_id) continue;
      if (!familyMemberMap.has(pod.product_family_id))
        familyMemberMap.set(pod.product_family_id, []);
      familyMemberMap.get(pod.product_family_id)!.push(pod.pod_product_id);
    }

    const famHistory: Record<string, unknown>[] = [];
    for (const fam of families ?? []) {
      const members = familyMemberMap.get(fam.product_family_id) ?? [];
      let wScore = 0,
        wV = 0,
        totalV = 0;
      for (const mid of members) {
        const ps = prodScoreMap.get(mid);
        if (!ps) continue;
        const w = Math.max(Number(ps.total_velocity_30d), 0.01);
        wScore += Number(ps.score) * w;
        wV += w;
        totalV += Number(ps.total_velocity_30d);
      }
      const famScore = wV > 0 ? r2(wScore / wV) : 5.0;
      famHistory.push({
        scope: "family",
        product_family_id: fam.product_family_id,
        snapshot_date: today,
        score: famScore,
        velocity_30d: r2(totalV),
        score_kind: "v2_split_global_local",
      });
    }
    for (let i = 0; i < famHistory.length; i += 25) {
      await supabase
        .from("lifecycle_score_history")
        .insert(famHistory.slice(i, i + 25));
    }

    const flagCounts: Record<string, number> = {};
    for (const f of [...allMachineDq, ...slotDqFlags]) {
      flagCounts[f.flag_type.toLowerCase()] =
        (flagCounts[f.flag_type.toLowerCase()] ?? 0) + 1;
    }

    return new Response(
      JSON.stringify({
        version: "v14",
        duration_ms: Date.now() - t0,
        slots_evaluated: slotsEval,
        products_evaluated: pods.length,
        families_aggregated: (families ?? []).length,
        sales_rows_fetched: sales.length,
        sales_pages: salesPages,
        auto_discovery: disc,
        score_delta: slotScoreDelta,
        flags: flagCounts,
      }),
      { headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("evaluate-lifecycle error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
