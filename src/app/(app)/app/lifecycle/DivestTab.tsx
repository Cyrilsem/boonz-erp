"use client";

// Divest Plan tab — DEAD + ROTATE-OUT phase-out, path-to-green and per-machine
// empty/move plan. Read-only from product_lifecycle_global + slot_lifecycle +
// v_live_shelf_stock + machines + pod_products. No writes. Stax S9, S10.

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  fetchInactiveProductIds,
  setProductLifecycleStatus,
} from "./lifecycleStatus";

interface ProdRow {
  id: string;
  name: string;
  signal: string;
  score: number;
  slots: number;
  machines: number;
  vel: number;
}
interface StockRow {
  machine: string;
  product: string;
  aisle: string;
  stock: number;
  max: number;
  price: number;
}
interface Hot {
  machine: string;
  lt: string;
  avg: number;
  slots: number;
  dead: number;
  rot: number;
}

const isWH = (m: string) => /^WH/i.test(m);

function Kpi({ v, l, color }: { v: string; l: string; color?: string }) {
  return (
    <div className="rounded-lg border border-neutral-200 bg-neutral-50 px-4 py-2.5 dark:border-neutral-800 dark:bg-neutral-900">
      <div className="text-xl font-bold" style={color ? { color } : undefined}>
        {v}
      </div>
      <div className="text-[10px] uppercase tracking-wide text-neutral-500">
        {l}
      </div>
    </div>
  );
}

export default function DivestTab() {
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [prods, setProds] = useState<ProdRow[]>([]);
  const [stock, setStock] = useState<StockRow[]>([]);
  const [hot, setHot] = useState<Hot[]>([]);
  const [inactiveList, setInactiveList] = useState<{ id: string; name: string }[]>([]);
  const [reloadKey, setReloadKey] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [kpi, setKpi] = useState<{
    overall: number;
    slots: number;
    dead: number;
    rot: number;
    ramp: number;
    ramped: number;
    remed: number;
    both: number;
  } | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const supabase = createClient();
        const inactiveIds = await fetchInactiveProductIds();
        const [globRes, podsRes, slotsRes, machinesRes] = await Promise.all([
          supabase
            .from("product_lifecycle_global")
            .select(
              "pod_product_id,signal,score,slot_count,machine_count,total_velocity_30d",
            )
            .limit(10000),
          supabase
            .from("pod_products")
            .select("pod_product_id,pod_product_name")
            .limit(10000),
          supabase
            .from("slot_lifecycle")
            .select("machine_id,pod_product_id,score,signal,velocity_30d")
            .eq("is_current", true)
            .eq("archived", false)
            .limit(20000),
          supabase
            .from("machines")
            .select("machine_id,official_name,location_type,include_in_refill")
            .limit(10000),
        ]);
        if (cancelled) return;
        const globs = globRes.data ?? [];
        const pods = podsRes.data ?? [];
        const slots = slotsRes.data ?? [];
        const machines = machinesRes.data ?? [];
        const pMap = new Map(
          pods.map((p) => [p.pod_product_id, p.pod_product_name as string]),
        );
        const mMap = new Map(machines.map((m) => [m.machine_id, m]));

        // inactive product list (for the manage/restore panel)
        setInactiveList(
          Array.from(inactiveIds)
            .map((id) => ({ id, name: pMap.get(id) ?? id }))
            .sort((a, b) => a.name.localeCompare(b.name)),
        );

        // divest products: global DEAD/ROTATE, deployed, NOT already inactive
        const divestRows: ProdRow[] = [];
        const divestIds = new Set<string>();
        for (const g of globs) {
          if (
            (g.signal === "DEAD — SWAP NOW" || g.signal === "ROTATE OUT") &&
            (g.slot_count ?? 0) >= 1 &&
            !inactiveIds.has(g.pod_product_id)
          ) {
            divestIds.add(g.pod_product_id);
            divestRows.push({
              id: g.pod_product_id,
              name: pMap.get(g.pod_product_id) ?? g.pod_product_id,
              signal: g.signal,
              score: Number(g.score),
              slots: g.slot_count ?? 0,
              machines: g.machine_count ?? 0,
              vel: Number(g.total_velocity_30d ?? 0),
            });
          }
        }
        divestRows.sort(
          (a, b) =>
            (a.signal === "DEAD — SWAP NOW" ? 0 : 1) -
              (b.signal === "DEAD — SWAP NOW" ? 0 : 1) || a.score - b.score,
        );
        setProds(divestRows);

        // live shelf stock for divest products
        const idList = Array.from(divestIds);
        let stockRows: StockRow[] = [];
        if (idList.length) {
          const lsRes = await supabase
            .from("v_live_shelf_stock")
            .select("machine_name,pod_product_id,aisle_code,current_stock,max_stock,price_aed")
            .in("pod_product_id", idList)
            .limit(20000);
          const ls = lsRes.data ?? [];
          // aggregate water cabinets (same machine+product, many aisles) is fine to list,
          // but collapse machine+product to one row summing stock for readability
          const sAgg = new Map<string, StockRow>();
          for (const r of ls) {
            const key = `${r.machine_name}|||${r.pod_product_id}`;
            const cur = sAgg.get(key);
            if (!cur) {
              sAgg.set(key, {
                machine: r.machine_name as string,
                product: pMap.get(r.pod_product_id) ?? (r.pod_product_id as string),
                aisle: r.aisle_code as string,
                stock: Number(r.current_stock ?? 0),
                max: Number(r.max_stock ?? 0),
                price: Number(r.price_aed ?? 0),
              });
            } else {
              cur.stock += Number(r.current_stock ?? 0);
              cur.max += Number(r.max_stock ?? 0);
              cur.aisle = "multi";
            }
          }
          stockRows = Array.from(sAgg.values()).filter((r) => r.stock > 0);
          stockRows.sort(
            (a, b) =>
              (isWH(a.machine) ? 1 : 0) - (isWH(b.machine) ? 1 : 0) ||
              a.machine.localeCompare(b.machine),
          );
        }
        setStock(stockRows);

        // path-to-green KPIs + hotspots from slot_lifecycle
        let sum = 0,
          n = 0,
          dead = 0,
          rot = 0,
          ramp = 0;
        const mAgg = new Map<
          string,
          { lt: string; sum: number; n: number; d: number; ro: number }
        >();
        for (const s of slots) {
          const mach = mMap.get(s.machine_id);
          if (!mach || mach.include_in_refill !== true) continue;
          if (inactiveIds.has(s.pod_product_id)) continue;
          const sc = Number(s.score);
          sum += sc;
          n += 1;
          if (s.signal === "DEAD — SWAP NOW") dead += 1;
          else if (s.signal === "ROTATE OUT") rot += 1;
          else if (s.signal === "RAMPING") ramp += 1;
          const mn = mach.official_name as string;
          const cur = mAgg.get(mn) ?? {
            lt: (mach.location_type as string) ?? "other",
            sum: 0,
            n: 0,
            d: 0,
            ro: 0,
          };
          cur.sum += sc;
          cur.n += 1;
          if (s.signal === "DEAD — SWAP NOW") cur.d += 1;
          else if (s.signal === "ROTATE OUT") cur.ro += 1;
          mAgg.set(mn, cur);
        }
        const scen = (rt?: number, mt?: number) => {
          let s2 = 0,
            n2 = 0;
          for (const s of slots) {
            const mach = mMap.get(s.machine_id);
            if (!mach || mach.include_in_refill !== true) continue;
            if (inactiveIds.has(s.pod_product_id)) continue;
            let sc = Number(s.score);
            if (rt != null && (s.signal === "DEAD — SWAP NOW" || s.signal === "ROTATE OUT")) sc = rt;
            else if (mt != null && s.signal === "RAMPING") sc = Math.max(sc, mt);
            s2 += sc;
            n2 += 1;
          }
          return n2 ? s2 / n2 : 0;
        };
        setKpi({
          overall: n ? sum / n : 0,
          slots: n,
          dead,
          rot,
          ramp,
          ramped: scen(undefined, 7.0),
          remed: scen(6.5, undefined),
          both: scen(6.5, 7.0),
        });
        const hotArr: Hot[] = Array.from(mAgg.entries())
          .map(([machine, v]) => ({
            machine,
            lt: v.lt,
            avg: v.n ? v.sum / v.n : 0,
            slots: v.n,
            dead: v.d,
            rot: v.ro,
          }))
          .filter((h) => h.dead + h.rot > 0)
          .sort((a, b) => b.dead + b.rot - (a.dead + a.rot))
          .slice(0, 10);
        setHot(hotArr);
        setLoading(false);
      } catch (e) {
        if (!cancelled) {
          setErr(e instanceof Error ? e.message : String(e));
          setLoading(false);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadKey]);

  async function toggleStatus(
    id: string,
    status: "active" | "inactive",
    reason?: string,
  ) {
    setBusy(id);
    try {
      await setProductLifecycleStatus(id, status, reason);
      setReloadKey((k) => k + 1);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  const totals = useMemo(() => {
    let vu = 0,
      vv = 0,
      wu = 0,
      wv = 0;
    for (const r of stock) {
      if (isWH(r.machine)) {
        wu += r.stock;
        wv += r.stock * r.price;
      } else {
        vu += r.stock;
        vv += r.stock * r.price;
      }
    }
    return { vu, vv, wu, wv };
  }, [stock]);

  if (loading)
    return <p className="text-neutral-500 text-sm">Loading divest plan…</p>;
  if (err)
    return <p className="text-red-600 text-sm">Failed to load: {err}</p>;
  if (!kpi) return null;

  const nDead = prods.filter((p) => p.signal === "DEAD — SWAP NOW").length;
  const nRot = prods.length - nDead;

  const th = "px-2 py-1.5 text-left font-semibold";
  const td = "px-2 py-1 border-t border-neutral-200 dark:border-neutral-800";

  return (
    <div className="space-y-5">
      <div>
        <h2 className="text-base font-semibold">Divest Plan — DEAD + Rotate Out</h2>
        <p className="text-xs text-neutral-500">
          {nDead} dead + {nRot} rotate-out products, fleet-wide. Catalogue
          decommission is cash &amp; discipline; the score lever is remediating
          the {kpi.dead + kpi.rot} dead/rotate slots and letting {kpi.ramp}{" "}
          ramping slots mature. All figures live.
        </p>
      </div>

      <div className="flex flex-wrap gap-2.5">
        <Kpi v={kpi.overall.toFixed(2)} l="Overall now /10" color="#d68910" />
        <Kpi v={`${kpi.ramped.toFixed(2)}`} l="If ramping matures" />
        <Kpi v={`${kpi.remed.toFixed(2)}`} l="If D+RO remediated" />
        <Kpi v={kpi.both.toFixed(2)} l="Both → target" color="#1e8449" />
      </div>

      <div className="rounded-lg border border-neutral-200 bg-neutral-50 px-4 py-3 text-xs dark:border-neutral-800 dark:bg-neutral-900">
        Most divest stock is already off the shop floor:{" "}
        <b>{totals.wu} units (~AED {Math.round(totals.wv).toLocaleString()})</b>{" "}
        in warehouse units, vs <b>{totals.vu} units (~AED{" "}
        {Math.round(totals.vv).toLocaleString()})</b> still in customer-facing
        machines. Divestment is mostly a warehouse write-off / redeploy
        decision.
      </div>

      {/* Divest products */}
      <div>
        <h3 className="mb-1.5 text-sm font-semibold">Products to divest</h3>
        <div className="overflow-x-auto rounded-lg border border-neutral-200 dark:border-neutral-800">
          <table className="w-full text-xs">
            <thead className="bg-neutral-100 dark:bg-neutral-900">
              <tr>
                <th className={th}>Product</th>
                <th className={th}>Signal</th>
                <th className={th}>Score</th>
                <th className={th}>Slots</th>
                <th className={th}>Machines</th>
                <th className={th}>v30</th>
                <th className={th}>Action</th>
              </tr>
            </thead>
            <tbody>
              {prods.map((p) => {
                const dead = p.signal === "DEAD — SWAP NOW";
                return (
                  <tr key={p.name}>
                    <td className={td}>{p.name}</td>
                    <td className={`${td} font-semibold`} style={{ color: dead ? "#c0392b" : "#d68910" }}>
                      {dead ? "DEAD" : "ROTATE"}
                    </td>
                    <td className={td}>{p.score.toFixed(1)}</td>
                    <td className={td}>{p.slots}</td>
                    <td className={td}>{p.machines}</td>
                    <td className={td}>{p.vel.toFixed(1)}</td>
                    <td className={td}>
                      <span className="mr-2">
                        {dead ? "Pull + swap now" : "Rotate out, drain stock"}
                      </span>
                      <button
                        onClick={() =>
                          toggleStatus(p.id, "inactive", "marked inactive from lifecycle Divest tab")
                        }
                        disabled={busy === p.id}
                        className="rounded border border-neutral-300 px-1.5 py-0.5 text-[10px] text-neutral-600 hover:bg-neutral-100 disabled:opacity-50 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-800"
                        title="Exclude this product from the lifecycle analysis"
                      >
                        {busy === p.id ? "…" : "Mark inactive"}
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {/* Per-machine empty/move */}
      <div>
        <h3 className="mb-1.5 text-sm font-semibold">
          Per-machine empty / move plan
        </h3>
        <div className="overflow-x-auto rounded-lg border border-neutral-200 dark:border-neutral-800">
          <table className="w-full text-xs">
            <thead className="bg-neutral-100 dark:bg-neutral-900">
              <tr>
                <th className={th}>Location</th>
                <th className={th}>Kind</th>
                <th className={th}>Product</th>
                <th className={th}>Aisle</th>
                <th className={th}>Units</th>
                <th className={th}>~AED</th>
                <th className={th}>Move</th>
              </tr>
            </thead>
            <tbody>
              {stock.map((r, i) => {
                const wh = isWH(r.machine);
                return (
                  <tr key={i}>
                    <td className={td}>{r.machine}</td>
                    <td className={td}>{wh ? "Warehouse" : "Venue"}</td>
                    <td className={td}>{r.product}</td>
                    <td className={td}>{r.aisle}</td>
                    <td className={td}>{r.stock}</td>
                    <td className={td}>{Math.round(r.stock * r.price).toLocaleString()}</td>
                    <td className={td}>
                      {wh ? "Redeploy or write off (FEFO)" : "Pull on next visit; swap shelf"}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {/* Hot-spots */}
      <div>
        <h3 className="mb-1.5 text-sm font-semibold">
          Remediation hot-spots (most dead/rotate slots)
        </h3>
        <div className="overflow-x-auto rounded-lg border border-neutral-200 dark:border-neutral-800">
          <table className="w-full text-xs">
            <thead className="bg-neutral-100 dark:bg-neutral-900">
              <tr>
                <th className={th}>Machine</th>
                <th className={th}>Type</th>
                <th className={th}>Avg</th>
                <th className={th}>Slots</th>
                <th className={th}>Dead</th>
                <th className={th}>Rotate</th>
                <th className={th}>Action</th>
              </tr>
            </thead>
            <tbody>
              {hot.map((h) => (
                <tr key={h.machine}>
                  <td className={td}>{h.machine}</td>
                  <td className={td}>{h.lt.slice(0, 4)}</td>
                  <td className={td}>{h.avg.toFixed(1)}</td>
                  <td className={td}>{h.slots}</td>
                  <td className={`${td} font-semibold`} style={{ color: h.dead ? "#c0392b" : undefined }}>{h.dead}</td>
                  <td className={td}>{h.rot}</td>
                  <td className={td}>{h.avg < 1.6 ? "RESET cabinet" : "Swap dead/rotate"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Manage inactive */}
      <div>
        <h3 className="mb-1.5 text-sm font-semibold">
          Inactive products ({inactiveList.length}) — excluded from analysis
        </h3>
        {inactiveList.length === 0 ? (
          <p className="text-xs text-neutral-500">
            None. Use “Mark inactive” above to retire a product from the
            lifecycle analysis.
          </p>
        ) : (
          <div className="flex flex-wrap gap-2">
            {inactiveList.map((p) => (
              <span
                key={p.id}
                className="inline-flex items-center gap-2 rounded-full border border-neutral-300 bg-neutral-50 px-2.5 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-900"
              >
                {p.name}
                <button
                  onClick={() => toggleStatus(p.id, "active", "restored from lifecycle Divest tab")}
                  disabled={busy === p.id}
                  className="rounded border border-neutral-300 px-1.5 py-0.5 text-[10px] text-neutral-600 hover:bg-neutral-100 disabled:opacity-50 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-800"
                >
                  {busy === p.id ? "…" : "Restore"}
                </button>
              </span>
            ))}
          </div>
        )}
      </div>

      <p className="text-[11px] text-neutral-500">
        Recommend-only. To execute the phase-outs, run the upstream strategic
        session (propose_decommission_plan) — nothing here writes to
        strategic_intents. Tannourine Water (water cabinets) is better handled
        as a cabinet-level rebalance than a product decommission.
      </p>
    </div>
  );
}
