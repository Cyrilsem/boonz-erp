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

function getSignal(score: number, trend: number): string {
  if (score >= 8.5 && trend > 5) return "DOUBLE DOWN";
  if (score >= 6.5 && trend > 5) return "KEEP GROWING";
  if (score >= 4.5 && score < 8.5 && trend >= 3.5 && trend <= 6.5)
    return "KEEP";
  if (score >= 2.5 && score < 4.5 && trend > 5) return "WATCH";
  if (score >= 2.5 && score < 4.5 && trend <= 5) return "WIND DOWN";
  if (score >= 1.0 && score < 2.5) return "ROTATE OUT";
  return "DEAD \u2014 SWAP NOW";
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

Deno.serve(async (_req) => {
  const t0 = Date.now();
  try {
    // ── Fetch all reference data in parallel ──────────────────────────────────
    const [
      machinesRes,
      planogramRes,
      podsRes,
      salesRes,
      podInvRes,
      nameConvRes,
    ] = await Promise.all([
      supabase
        .from("machines")
        .select("machine_id,official_name,location_type,include_in_refill")
        .eq("include_in_refill", true)
        .limit(10000),
      supabase
        .from("planogram")
        .select("machine_id,shelf_id,shelf_code,pod_product_id,effective_from")
        .eq("is_active", true)
        .not("pod_product_id", "is", null)
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

    const machines = machinesRes.data ?? [];
    const planogram = planogramRes.data ?? [];
    const pods = podsRes.data ?? [];
    const sales = salesRes.data ?? [];
    const podInv = podInvRes.data ?? [];
    const nameConv = nameConvRes.data ?? [];

    // Lookup maps
    const machineMap = new Map(machines.map((m) => [m.machine_id, m]));
    const podByName = new Map(
      pods.map((p) => [p.pod_product_name.toLowerCase(), p.pod_product_id]),
    );
    const nameAlias = new Map(
      nameConv.map((n) => [
        n.original_name?.toLowerCase(),
        n.official_name?.toLowerCase(),
      ]),
    );

    const resolvePodId = (name: string): string | null => {
      const lo = name.toLowerCase();
      return (
        podByName.get(lo) ?? podByName.get(nameAlias.get(lo) ?? "") ?? null
      );
    };

    // ── Dark machines (0 sales in 14d) ────────────────────────────────────────
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

    // ── Phase 1: Auto-discovery ───────────────────────────────────────────────
    const [existingSlotsRes, existingProductsRes] = await Promise.all([
      supabase
        .from("slot_lifecycle")
        .select("machine_id,shelf_id,score,first_seen_at")
        .limit(10000),
      supabase
        .from("product_lifecycle_global")
        .select("pod_product_id")
        .limit(10000),
    ]);

    const existingSlots = existingSlotsRes.data ?? [];
    const existingSlotKeys = new Set(
      existingSlots.map((s) => `${s.machine_id}:${s.shelf_id}`),
    );
    const existingSlotMap = new Map(
      existingSlots.map((s) => [`${s.machine_id}:${s.shelf_id}`, s]),
    );
    const existingProdIds = new Set(
      (existingProductsRes.data ?? []).map((p) => p.pod_product_id),
    );

    const disc = {
      new_machines: 0,
      new_slots: 0,
      new_products: 0,
      new_families: 0,
      archived_slots: 0,
    };

    // New slots
    const planogramKeys = new Set(
      planogram.map((p) => `${p.machine_id}:${p.shelf_id}`),
    );
    const newSlotRows = planogram.filter(
      (p) => !existingSlotKeys.has(`${p.machine_id}:${p.shelf_id}`),
    );
    disc.new_slots = newSlotRows.length;
    for (let i = 0; i < newSlotRows.length; i += 100) {
      await supabase.from("slot_lifecycle").upsert(
        newSlotRows.slice(i, i + 100).map((p) => ({
          machine_id: p.machine_id,
          shelf_id: p.shelf_id,
          shelf_code: p.shelf_code ?? "",
          pod_product_id: p.pod_product_id,
          score: 5.0,
          signal: "KEEP",
        })),
        { onConflict: "machine_id,shelf_id" },
      );
    }

    // New products
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

    // Archive removed slots
    const toArchive = existingSlots.filter(
      (s) => !planogramKeys.has(`${s.machine_id}:${s.shelf_id}`),
    );
    for (const s of toArchive) {
      await supabase
        .from("slot_lifecycle")
        .update({ archived: true })
        .eq("machine_id", s.machine_id)
        .eq("shelf_id", s.shelf_id);
      disc.archived_slots++;
    }

    // ── Phase 2: DQ flags (resolve stale, insert fresh) ──────────────────────
    // Resolve stale machine-scope flags
    await supabase
      .from("lifecycle_data_quality_flags")
      .update({ resolved_at: new Date().toISOString() })
      .in("flag_type", ["MACHINE_DARK", "UNNORMALIZED_LOCATION"])
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
    }

    for (let i = 0; i < dqFlags.length; i += 25) {
      await supabase
        .from("lifecycle_data_quality_flags")
        .insert(dqFlags.slice(i, i + 25));
    }

    // ── Phase 3: Build sales map & compute scores ─────────────────────────────
    // sales map: `${machine_id}:${pod_product_id}` → DailySales
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

    // Active slots to score (must have valid location_type)
    const scorableSlots = planogram.filter(
      (p) =>
        p.pod_product_id &&
        VALID_LOCATION_TYPES.has(
          machineMap.get(p.machine_id)?.location_type ?? "",
        ),
    );

    // First pass: compute velocities
    type VData = {
      v7: number;
      v14: number;
      v30: number;
      trend: number;
      cons: number;
      daily: DailySales;
    };
    const vMap = new Map<string, VData>(); // slot key → velocities
    for (const slot of scorableSlots) {
      const daily =
        salesMap.get(`${slot.machine_id}:${slot.pod_product_id}`) ?? new Map();
      vMap.set(`${slot.machine_id}:${slot.shelf_id}`, {
        v7: velocityN(daily, 7),
        v14: velocityN(daily, 14),
        v30: velocityN(daily, 30),
        trend: trendComponent(daily),
        cons: consistencyComponent(daily),
        daily,
      });
    }

    // Build archetype baselines: (location_type:pod_product_id) → [v30 from non-dark machines]
    const arcMap = new Map<string, number[]>(); // `${locType}:${podId}` → velocities
    const allArcMap = new Map<string, number[]>(); // `${podId}` → all velocities (fallback)
    for (const slot of scorableSlots) {
      if (darkMachines.has(slot.machine_id)) continue;
      const m = machineMap.get(slot.machine_id);
      if (!m?.location_type) continue;
      const v = vMap.get(`${slot.machine_id}:${slot.shelf_id}`);
      if (!v) continue;
      const k1 = `${m.location_type}:${slot.pod_product_id}`;
      const k2 = slot.pod_product_id!;
      if (!arcMap.has(k1)) arcMap.set(k1, []);
      arcMap.get(k1)!.push(v.v30);
      if (!allArcMap.has(k2)) allArcMap.set(k2, []);
      allArcMap.get(k2)!.push(v.v30);
    }

    // DQ: LOW_CONFIDENCE_BASELINE
    const lowBaselineFlags: typeof dqFlags = [];
    const podBaselineMap = new Map<string, { flag: boolean }>(); // track per product

    // Second pass: compute scores
    const today = new Date().toISOString().split("T")[0];
    const slotUpdates: Record<string, unknown>[] = [];
    const slotHistory: Record<string, unknown>[] = [];
    const slotDqFlags: typeof dqFlags = [];

    // For global aggregation: pod_product_id → { wScore, wV, totalV30, trendSum, trendCount, machineIds }
    const globalAgg = new Map<
      string,
      {
        wScore: number;
        wV: number;
        totalV30: number;
        trendSum: number;
        trendCnt: number;
        machines: Set<string>;
        bestLocScore: Map<string, number[]>;
        worstLocScore: Map<string, number[]>;
      }
    >();

    let slotsEval = 0;
    const slotScoreDelta = { up: 0, down: 0 };

    for (const slot of scorableSlots) {
      const m = machineMap.get(slot.machine_id)!;
      const slotKey = `${slot.machine_id}:${slot.shelf_id}`;
      const v = vMap.get(slotKey)!;

      // Archetype baseline
      const arcKey = `${m.location_type}:${slot.pod_product_id}`;
      const arcVelocities = arcMap.get(arcKey) ?? [];
      let baseline: number;
      let lowConfBaseline = false;
      if (arcVelocities.length >= 3) {
        baseline = Math.max(0.1, median(arcVelocities));
      } else {
        const all = allArcMap.get(slot.pod_product_id!) ?? [];
        baseline = all.length > 0 ? Math.max(0.1, median(all)) : 0.5;
        lowConfBaseline = true;
      }

      if (lowConfBaseline && !podBaselineMap.has(slot.pod_product_id!)) {
        podBaselineMap.set(slot.pod_product_id!, { flag: true });
        lowBaselineFlags.push({
          flag_type: "LOW_CONFIDENCE_BASELINE",
          severity: "info",
          scope: "product",
          pod_product_id: slot.pod_product_id,
          message: `Archetype baseline for this product computed from < 3 slots in ${m.location_type}`,
        });
      }

      const vc = Math.min(10, (v.v30 / baseline) * 5);
      const tc = v.trend;
      const cc = v.cons;
      let score = r2(vc * 0.6 + tc * 0.25 + cc * 0.15);

      const existingSlot = existingSlotMap.get(slotKey);
      const firstSeen = existingSlot?.first_seen_at ?? new Date().toISOString();
      const ageD = Math.floor(
        (Date.now() - new Date(firstSeen).getTime()) / 86400000,
      );

      // Cap for new slots
      if (ageD < 14) {
        score = Math.min(score, 4.5);
        slotDqFlags.push({
          flag_type: "INSUFFICIENT_DATA",
          severity: "info",
          scope: "slot",
          machine_id: slot.machine_id,
          shelf_id: slot.shelf_id,
          message: `Slot age ${ageD}d < 14 days — score capped at TRIAL`,
        });
      }

      // Velocity outlier
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

      const prevScore = existingSlot?.score ? Number(existingSlot.score) : null;
      if (prevScore !== null) {
        if (score - prevScore >= 0.5) slotScoreDelta.up++;
        else if (prevScore - score >= 0.5) slotScoreDelta.down++;
      }

      const signal = getSignal(score, tc);

      slotUpdates.push({
        machine_id: slot.machine_id,
        shelf_id: slot.shelf_id,
        shelf_code: slot.shelf_code ?? "",
        pod_product_id: slot.pod_product_id,
        score,
        previous_score: prevScore,
        velocity_component: r2(vc),
        trend_component: r2(tc),
        consistency_component: r2(cc),
        velocity_7d: r2(v.v7),
        velocity_14d: r2(v.v14),
        velocity_30d: r2(v.v30),
        archetype_baseline_velocity: r2(baseline),
        signal,
        slot_age_days: ageD,
        last_evaluated_at: new Date().toISOString(),
      });

      slotHistory.push({
        scope: "slot",
        machine_id: slot.machine_id,
        shelf_id: slot.shelf_id,
        pod_product_id: slot.pod_product_id,
        snapshot_date: today,
        score,
        velocity_30d: r2(v.v30),
      });

      // Aggregate for global
      const pid = slot.pod_product_id!;
      if (!globalAgg.has(pid)) {
        globalAgg.set(pid, {
          wScore: 0,
          wV: 0,
          totalV30: 0,
          trendSum: 0,
          trendCnt: 0,
          machines: new Set(),
          bestLocScore: new Map(),
          worstLocScore: new Map(),
        });
      }
      const agg = globalAgg.get(pid)!;
      const weight = Math.max(v.v30, 0.01);
      agg.wScore += score * weight;
      agg.wV += weight;
      agg.totalV30 += v.v30;
      agg.trendSum += tc;
      agg.trendCnt++;
      agg.machines.add(slot.machine_id);
      if (!agg.bestLocScore.has(m.location_type))
        agg.bestLocScore.set(m.location_type, []);
      agg.bestLocScore.get(m.location_type)!.push(score);

      slotsEval++;
    }

    // Batch upsert slot_lifecycle
    for (let i = 0; i < slotUpdates.length; i += 100) {
      await supabase
        .from("slot_lifecycle")
        .upsert(slotUpdates.slice(i, i + 100), {
          onConflict: "machine_id,shelf_id",
        });
    }

    // Batch insert history
    for (let i = 0; i < slotHistory.length; i += 25) {
      await supabase
        .from("lifecycle_score_history")
        .insert(slotHistory.slice(i, i + 25));
    }

    // Insert slot DQ flags
    const allSlotFlags = [...lowBaselineFlags, ...slotDqFlags];
    for (let i = 0; i < allSlotFlags.length; i += 25) {
      await supabase
        .from("lifecycle_data_quality_flags")
        .insert(allSlotFlags.slice(i, i + 25));
    }

    // ── Phase 4: Global product aggregation ──────────────────────────────────
    const prodUpdates: Record<string, unknown>[] = [];
    const prodHistory: Record<string, unknown>[] = [];

    for (const pod of pods) {
      const agg = globalAgg.get(pod.pod_product_id);
      const globalScore = agg ? r2(agg.wScore / agg.wV) : 5.0;
      const globalTrend = agg ? r2(agg.trendSum / agg.trendCnt) : 5.0;
      const totalV30 = agg ? r2(agg.totalV30) : 0;
      const machineCount = agg ? agg.machines.size : 0;

      // Best/worst location_type by avg score
      let bestLoc: string | null = null,
        worstLoc: string | null = null;
      let bestScore = -1,
        worstScore = 11;
      if (agg) {
        for (const [loc, scores] of agg.bestLocScore) {
          const avg = scores.reduce((a, b) => a + b, 0) / scores.length;
          if (avg > bestScore) {
            bestScore = avg;
            bestLoc = loc;
          }
          if (avg < worstScore) {
            worstScore = avg;
            worstLoc = loc;
          }
        }
      }

      const signal = getSignal(globalScore, globalTrend);

      prodUpdates.push({
        pod_product_id: pod.pod_product_id,
        score: globalScore,
        trend_component: globalTrend,
        machine_count: machineCount,
        total_velocity_30d: totalV30,
        signal,
        best_location_type: bestLoc,
        worst_location_type: worstLoc,
        last_evaluated_at: new Date().toISOString(),
      });

      prodHistory.push({
        scope: "product",
        pod_product_id: pod.pod_product_id,
        snapshot_date: today,
        score: globalScore,
        velocity_30d: totalV30,
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

    // ── Phase 5: Family aggregation ───────────────────────────────────────────
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
      });
    }
    for (let i = 0; i < famHistory.length; i += 25) {
      await supabase
        .from("lifecycle_score_history")
        .insert(famHistory.slice(i, i + 25));
    }

    // ── Summary ───────────────────────────────────────────────────────────────
    const flagCounts: Record<string, number> = {};
    for (const f of [...dqFlags, ...allSlotFlags]) {
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
