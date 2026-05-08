import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

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

// Phase B.1.1: machines within MACHINE_RAMP_DAYS of their first sale (or
// creation if no sales yet) are too young to judge — signals get overridden
// to "RAMPING" so we don't prematurely brand products as DEAD/ROTATE OUT.
const MACHINE_RAMP_DAYS = 30;

// Phase B.3: EMA blend factor for compound scoring with memory.
// α=0.67 → recent ≈ 2× historical (the "compound upwards/downwards" pattern CS asked for).
const EMA_ALPHA = 0.67;

// Phase B.3: signalV2 — hard-gate on both score AND trend.
// Score is now velocity-only (Global = rank-percentile, Local = spectrum-vs-product-avg).
// Trend is a separate axis. DOUBLE DOWN / KEEP GROWING require BOTH to clear.
function getSignalV2(score: number, trend: number): string {
  if (score >= 8 && trend >= 7) return "DOUBLE DOWN";
  if (score >= 6 && trend >= 7) return "KEEP GROWING";
  if (score >= 4 && trend >= 4) return "KEEP";
  if (score >= 4 && trend < 4) return "WIND DOWN";
  if (score >= 2 && trend >= 7) return "WATCH";
  if (score >= 2) return "WIND DOWN";
  if (score >= 1) return "ROTATE OUT";
  return "DEAD — SWAP NOW";
}

function median(arr: number[]): number {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid];
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

function trendComponent(daily: DailySales): number {
  let last14 = 0,
    prior14 = 0;
  const now = Date.now();
  for (const [d, q] of daily) {
    const age = (now - new Date(d).getTime()) / 86400000;
    if (age <= 14) last14 += q;
    else if (age <= 28) prior14 += q;
  }
  const l = last14 / 14;
  const p = prior14 / 14;
  if (p === 0 && l === 0) return 5;
  if (p === 0) return 10;
  const pct = (l - p) / p;
  if (pct >= 0.5) return 10;
  if (pct >= 0.1) return 5 + ((pct - 0.1) / 0.4) * 5;
  if (pct >= -0.1) return 5;
  if (pct >= -0.5) return 5 - ((Math.abs(pct) - 0.1) / 0.4) * 5;
  return 0;
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

Deno.serve(async (_req) => {
  const t0 = Date.now();
  try {
    const [
      machinesRes,
      snapshotsRes,
      shelfConfigsRes,
      podsRes,
      salesRes,
      podInvRes,
      nameConvRes,
    ] = await Promise.all([
      supabase
        .from("machines")
        .select(
          "machine_id,official_name,location_type,include_in_refill,created_at",
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
        .from("sales_history")
        .select("machine_id,pod_product_name,qty,transaction_date")
        .eq("delivery_status", "Successful")
        .gte(
          "transaction_date",
          new Date(Date.now() - 62 * 86400000).toISOString(),
        )
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

    // Phase B.1.2: all-time first-sale-per-machine for ramping detection.
    const firstSaleRes = await supabase
      .from("v_machine_first_sale")
      .select("machine_id,first_sale_at")
      .limit(10000);

    const machines = machinesRes.data ?? [];
    const snapshots = snapshotsRes.data ?? [];
    const shelfConfigs = shelfConfigsRes.data ?? [];
    const pods = podsRes.data ?? [];
    const sales = salesRes.data ?? [];
    const podInv = podInvRes.data ?? [];
    const nameConv = nameConvRes.data ?? [];
    const firstSales = firstSaleRes.data ?? [];

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
      return (
        podByName.get(k) ?? podByName.get(nameAlias.get(k) ?? "") ?? null
      );
    };

    // ── Reality builder (snapshot-anchored, B.1) ────────────────────────────
    const shelfIdMap = new Map<string, string>();
    for (const sc of shelfConfigs) {
      if (sc.machine_id && sc.shelf_code) {
        shelfIdMap.set(`${sc.machine_id}:${sc.shelf_code}`, sc.shelf_id);
      }
    }

    const latestSnap = new Map<string, typeof snapshots[0]>();
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

    // ── Phase B.5: Auto-archive ghost rows for inactive/excluded machines ───
    // Any slot_lifecycle row whose machine is NOT include_in_refill=true should
    // not appear in the matrix. Archive them so they don't accumulate as
    // machines get deactivated. The `machines` array above already filters by
    // include_in_refill=true, so any row outside its set is a ghost.
    const activeMachineIds = new Set(machines.map((m) => m.machine_id));
    const { data: ghostRows } = await supabase
      .from("slot_lifecycle")
      .select("machine_id")
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

    // ── Ramping check (B.1.2) ────────────────────────────────────────────────
    const firstSaleByMachine = new Map<string, Date>();
    for (const r of firstSales) {
      if (r.machine_id && r.first_sale_at) {
        firstSaleByMachine.set(r.machine_id, new Date(r.first_sale_at));
      }
    }
    const isRampingMachine = (machineId: string): boolean => {
      const m = machineMap.get(machineId);
      if (!m) return false;
      const firstSale = firstSaleByMachine.get(machineId);
      if (firstSale) {
        const days = (Date.now() - firstSale.getTime()) / 86400000;
        return days < MACHINE_RAMP_DAYS;
      }
      if (m.created_at) {
        const days =
          (Date.now() - new Date(m.created_at).getTime()) / 86400000;
        if (days < MACHINE_RAMP_DAYS) return true;
      }
      return false;
    };

    // ── Dark machines (0 sales in 14d) ───────────────────────────────────────
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

    // ── Existing slot_lifecycle state (for EMA prior + rotation detection) ──
    const [existingSlotsRes, existingProductsRes] = await Promise.all([
      supabase
        .from("slot_lifecycle")
        .select(
          "machine_id,shelf_id,pod_product_id,score,first_seen_at,is_current",
        )
        .eq("archived", false)
        .limit(20000),
      supabase
        .from("product_lifecycle_global")
        .select("pod_product_id,score")
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

    const disc = {
      new_machines: 0,
      new_slots: 0,
      new_products: 0,
      new_families: 0,
      archived_slots: 0,
      rotations: 0,
    };

    const nowIso = new Date().toISOString();

    // ── Phase 1.5: Detect rotations — flip prior is_current=false ───────────
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

    // ── Phase 1.6: Archive slots whose shelf_id vanished ────────────────────
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

    // New product seeds (unchanged from prior phases)
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

    // ── Phase 2: DQ flags (resolve stale, insert fresh) ─────────────────────
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
      if (darkMachines.has(m.machine_id)) {
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
          message: `location_type '${m.location_type}' is null or unnormalized`,
        });
      }
      if (isRampingMachine(m.machine_id)) {
        const firstSale = firstSaleByMachine.get(m.machine_id);
        const daysSinceFirstSale = firstSale
          ? Math.floor((Date.now() - firstSale.getTime()) / 86400000)
          : null;
        const daysSinceCreation = m.created_at
          ? Math.floor(
              (Date.now() - new Date(m.created_at).getTime()) / 86400000,
            )
          : null;
        dqFlags.push({
          flag_type: "MACHINE_RAMPING",
          severity: "info",
          scope: "machine",
          machine_id: m.machine_id,
          message: firstSale
            ? `${m.official_name} ramping — ${daysSinceFirstSale}/${MACHINE_RAMP_DAYS}d since first sale. Lifecycle signal capped at RAMPING.`
            : `${m.official_name} active but not yet selling — ${daysSinceCreation ?? "?"}d since deployment. Lifecycle signal = RAMPING.`,
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

    // ── Phase 3a (B.3): Build per-(machine,product) sales velocity ─────────
    const salesMap = new Map<string, DailySales>();
    for (const s of sales) {
      const pid = resolvePodId(s.pod_product_name);
      if (!pid) continue;
      const k = `${s.machine_id}:${pid}`;
      if (!salesMap.has(k)) salesMap.set(k, new Map());
      const ds = salesMap.get(k)!;
      const d = s.transaction_date.substring(0, 10);
      ds.set(d, (ds.get(d) ?? 0) + Number(s.qty));
    }

    // Phase B.4: skip dark machines (no sales in 14d) — their slots have v30=0
    // across the board and would just pollute the matrix with score=0.41/DEAD
    // signals. They're already surfaced via the MACHINE_DARK DQ flag above.
    const scorableSlots = reality.filter(
      (r) =>
        !darkMachines.has(r.machine_id) &&
        VALID_LOCATION_TYPES.has(
          machineMap.get(r.machine_id)?.location_type ?? "",
        ),
    );

    type VData = {
      v7: number;
      v14: number;
      v30: number;
      trend: number;
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
        trend: trendComponent(daily),
        cons: consistencyComponent(daily),
        daily,
      });
    }

    // ── Phase 3b (B.3): Per-product totals BEFORE per-slot scoring ────────
    // For each pod_product, aggregate v30 across its current slots and count
    // unique machines. This is the input to per_machine_avg_v30 for both Global
    // formula and Local spectrum.
    type ProductAgg = {
      total_v30: number;
      machine_set: Set<string>;
      ramping_machine_set: Set<string>;
      trend_sum: number;
      trend_cnt: number;
      best_loc: Map<string, number[]>;
    };
    const productAgg = new Map<string, ProductAgg>();
    for (const slot of scorableSlots) {
      const v = vMap.get(
        `${slot.machine_id}:${slot.shelf_id}:${slot.pod_product_id}`,
      );
      if (!v) continue;
      const m = machineMap.get(slot.machine_id);
      if (!m?.location_type) continue;
      let agg = productAgg.get(slot.pod_product_id);
      if (!agg) {
        agg = {
          total_v30: 0,
          machine_set: new Set(),
          ramping_machine_set: new Set(),
          trend_sum: 0,
          trend_cnt: 0,
          best_loc: new Map(),
        };
        productAgg.set(slot.pod_product_id, agg);
      }
      agg.total_v30 += v.v30;
      agg.machine_set.add(slot.machine_id);
      if (isRampingMachine(slot.machine_id))
        agg.ramping_machine_set.add(slot.machine_id);
      agg.trend_sum += v.trend;
      agg.trend_cnt++;
      if (!agg.best_loc.has(m.location_type))
        agg.best_loc.set(m.location_type, []);
    }

    // Compute per_machine_avg_v30 per product (for Global rank + Local spectrum)
    const productPerMachineAvg = new Map<string, number>();
    for (const [pid, agg] of productAgg) {
      const machineCount = agg.machine_set.size;
      const avg = machineCount > 0 ? agg.total_v30 / machineCount : 0;
      productPerMachineAvg.set(pid, avg);
    }

    // ── Phase 3c (B.3): Compute Global rank-percentile across all products ──
    // Sort products by per_machine_avg_v30 DESC, assign 1-indexed rank.
    // score_raw = (1 - (rank-1)/(N-1)) * 10 → top product = 10, bottom = 0.
    const productEntriesSorted = [...productPerMachineAvg.entries()].sort(
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

    // ── Phase 3d (B.3): Per-slot scoring with spectrum + EMA ───────────────
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

      const productAvg = productPerMachineAvg.get(slot.pod_product_id) ?? 0;

      // B.3: Local spectrum — 5.0 = at product's per-machine avg, 10.0 = 2× avg.
      let spectrum_ratio: number;
      if (productAvg <= 0) {
        spectrum_ratio = 1.0; // neutral — no anchor available
      } else {
        spectrum_ratio = v.v30 / productAvg;
      }
      let local_score_raw = clip01_10(spectrum_ratio * 5);

      const existingSlot = existingByLedger.get(ledgerKey);
      const firstSeen = existingSlot?.first_seen_at ?? new Date().toISOString();
      const ageD = Math.floor(
        (Date.now() - new Date(firstSeen).getTime()) / 86400000,
      );

      // Slot-age cap: still applies for new slots (< 14d)
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

      // EMA blend with prior slot score
      const priorScore = existingSlot?.score
        ? Number(existingSlot.score)
        : null;
      const score = ema(local_score_raw, priorScore);

      if (priorScore !== null) {
        if (score - priorScore >= 0.5) slotScoreDelta.up++;
        else if (priorScore - score >= 0.5) slotScoreDelta.down++;
      }

      const tc = v.trend;
      const rawSignal = getSignalV2(score, tc);
      const signal = isRampingMachine(slot.machine_id) ? "RAMPING" : rawSignal;

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

    // ── Phase 4 (B.3): Global product upsert with rank-percentile + EMA ────
    const prodUpdates: Record<string, unknown>[] = [];
    const prodHistory: Record<string, unknown>[] = [];

    for (const pod of pods) {
      const agg = productAgg.get(pod.pod_product_id);
      const perMachineAvg = productPerMachineAvg.get(pod.pod_product_id) ?? 0;
      const rawScore = productGlobalRawScore.get(pod.pod_product_id) ?? 0;
      const rank = productGlobalRank.get(pod.pod_product_id) ?? null;
      const totalV30 = agg ? r2(agg.total_v30) : 0;
      const machineCount = agg ? agg.machine_set.size : 0;
      const rampingCount = agg ? agg.ramping_machine_set.size : 0;
      const globalTrend = agg && agg.trend_cnt > 0
        ? r2(agg.trend_sum / agg.trend_cnt)
        : 5.0;

      // EMA blend
      const priorScore = existingProductScores.get(pod.pod_product_id) ?? null;
      const score = ema(rawScore, priorScore);

      // best/worst location_type by avg slot score (still useful as a flag)
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

      const signal = getSignalV2(score, globalTrend);

      prodUpdates.push({
        pod_product_id: pod.pod_product_id,
        score,
        score_raw: r2(rawScore),
        global_rank: rank,
        per_machine_avg_v30: r2(perMachineAvg),
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

    // ── Phase 5: Family aggregation (unchanged) ────────────────────────────
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
        duration_ms: Date.now() - t0,
        slots_evaluated: slotsEval,
        products_evaluated: pods.length,
        families_aggregated: (families ?? []).length,
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
