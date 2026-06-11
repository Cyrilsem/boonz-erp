"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import Script from "next/script";
import { createClient } from "@/lib/supabase/client";
import {
  type VoxConsumerReport,
  type VoxCommercialReport,
  VOX_PODS,
  MACHINE_LABELS,
  shortMachine,
  WALLET_NAMES,
  FUND_COLORS,
  CARD_COLORS,
  PROD_COLORS,
  aed,
  pct,
  fetchVoxConsumerReport,
  fetchVoxCommercialReport,
} from "@/lib/vox-data";

const GRID = "#e8e4de";
const MERC = "#24544a";
const MIRD = "#e1b460";
const COMBINED = "#4a7a6d";
const PLUG = {
  legend: { display: false },
  tooltip: {
    backgroundColor: "#ffffff",
    borderColor: GRID,
    borderWidth: 1,
    titleColor: "#0a0a0a",
    bodyColor: "#6b6860",
    padding: 10,
  },
};

function useChart(
  ref: React.RefObject<HTMLCanvasElement | null>,
  cfg: any,
  deps: any[],
) {
  const inst = useRef<any>(null);
  useEffect(() => {
    const C = (window as any).Chart;
    if (!C || !ref.current || !cfg) return;
    if (inst.current) inst.current.destroy();
    inst.current = new C(ref.current, cfg);
    return () => {
      if (inst.current) {
        inst.current.destroy();
        inst.current = null;
      }
    };
  }, deps);
}

const CSS = `@import url('https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap');
:root{--bg:#faf9f7;--surface:#ffffff;--surface2:#f5f2ee;--border:#e8e4de;--merc:#24544a;--merc-dim:rgba(36,84,74,0.10);--mird:#e1b460;--mird-dim:rgba(225,180,96,0.12);--amber:#d97706;--red:#dc2626;--white:#0a0a0a;--grey:#6b6860;--grey2:#9a948e;--font-head:'Plus Jakarta Sans',sans-serif;--font-mono:'Plus Jakarta Sans',sans-serif}
.vr{background:var(--bg);color:var(--white);font-family:var(--font-mono);font-size:13px;line-height:1.5;min-height:100vh}.vr *{box-sizing:border-box}
.vr nav{position:sticky;top:0;z-index:100;background:rgba(250,249,247,0.97);backdrop-filter:blur(12px);border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 24px;flex-wrap:wrap}
.nb{font-family:var(--font-head);font-weight:800;font-size:15px;padding:14px 24px 14px 0;border-right:1px solid var(--border);margin-right:8px;letter-spacing:-0.5px}
.nt{padding:12px 16px;font-size:12px;font-family:var(--font-head);font-weight:500;letter-spacing:0.06em;text-transform:uppercase;color:var(--grey);cursor:pointer;border-bottom:3px solid transparent;transition:all 0.2s;white-space:nowrap}.nt:hover{color:var(--white)}.nt.a{color:var(--white);font-weight:700;border-bottom-color:#0a0a0a}
.nm{margin-left:auto;font-size:10px;color:var(--grey);display:flex;gap:16px;align-items:center}
.sb{padding:3px 10px;border-radius:2px;font-size:10px;font-weight:500}.sbm{background:var(--merc-dim);color:var(--merc);border:1px solid rgba(59,130,246,0.3)}.sbi{background:var(--mird-dim);color:var(--mird);border:1px solid rgba(16,185,129,0.3)}
.pg{padding:28px 24px;max-width:1400px;margin:0 auto;animation:vf .3s ease}@keyframes vf{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
.sl{font-size:10px;letter-spacing:0.12em;text-transform:uppercase;color:var(--grey);margin-bottom:14px;display:flex;align-items:center;gap:10px}.sl::after{content:'';flex:1;height:1px;background:var(--border)}
.vr h2{font-family:var(--font-head);font-weight:700;font-size:22px;letter-spacing:-0.5px;margin-bottom:4px}.vr h3{font-family:var(--font-head);font-weight:600;font-size:15px;margin-bottom:12px}
.gr{display:grid;gap:14px}.g2{grid-template-columns:1fr 1fr}.g3{grid-template-columns:1fr 1fr 1fr}@media(max-width:900px){.g2,.g3{grid-template-columns:1fr}}
.cd{background:var(--surface);border:1px solid var(--border);border-radius:6px;padding:18px 20px}
.kp{background:var(--surface);border:1px solid var(--border);border-radius:6px;padding:16px 18px;position:relative;overflow:hidden}.kp::before{content:'';position:absolute;top:0;left:0;right:0;height:2px}.kp.km::before{background:var(--merc)}.kp.ki::before{background:var(--mird)}.kp.ka::before{background:var(--amber)}.kp.kr::before{background:var(--red)}.kp.kc::before{background:#8B5CF6}
.kl{font-size:10px;letter-spacing:0.08em;text-transform:uppercase;color:var(--grey);margin-bottom:8px}.kv{font-family:var(--font-head);font-size:26px;font-weight:800;letter-spacing:-1px;line-height:1}.ks{font-size:10px;color:var(--grey);margin-top:6px}
.kv.vm{color:var(--merc)}.kv.vi{color:var(--mird)}.kv.va{color:var(--amber)}.kv.vr2{color:var(--red)}.kv.vc{color:#8B5CF6}
.cw{position:relative}.cw canvas{width:100%!important}
.sr{display:grid;grid-template-columns:repeat(6,1fr);gap:10px;margin-bottom:20px}@media(max-width:1000px){.sr{grid-template-columns:repeat(3,1fr)}}
.ss{display:grid;grid-template-columns:1fr 1fr;border-radius:6px;overflow:hidden;margin-bottom:14px}
.si{padding:10px 16px;display:flex;justify-content:space-between;align-items:center}.si.sm{background:var(--merc-dim);border:1px solid rgba(36,84,74,0.2)}.si.sd{background:var(--mird-dim);border:1px solid rgba(225,180,96,0.2);border-left:none}
.si .sn{font-family:var(--font-head);font-weight:700;font-size:13px}.sn.snm{color:var(--merc)}.sn.sni{color:var(--mird)}
.si .st{font-size:11px;color:var(--grey2);display:flex;gap:16px}.si .st strong{color:var(--white)}
.pr{display:flex;align-items:center;gap:10px;margin-bottom:8px}.pl{font-size:11px;color:var(--grey2);width:140px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex-shrink:0}.pb{flex:1;height:6px;background:var(--border);border-radius:2px;overflow:hidden}.pf{height:100%;border-radius:2px;transition:width .8s ease}.pv{font-size:11px;color:var(--white);width:52px;text-align:right;font-weight:500;flex-shrink:0}.pp{font-size:10px;color:var(--grey);width:30px;text-align:right;flex-shrink:0}
.lg{display:flex;gap:16px;align-items:center;flex-wrap:wrap;margin-bottom:12px}.li{display:flex;align-items:center;gap:6px;font-size:11px;color:var(--grey2)}.ld{width:10px;height:10px;border-radius:2px;flex-shrink:0}
.tw{overflow-x:auto;border-radius:6px;border:1px solid var(--border)}.vr table{width:100%;border-collapse:collapse;font-size:11.5px;min-width:900px}.vr thead th{background:var(--surface2);padding:10px 12px;text-align:left;font-size:9.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--grey);font-weight:500;white-space:nowrap;border-bottom:1px solid var(--border)}.vr thead th.r{text-align:right}.vr thead th.c{text-align:center}.vr tbody tr{border-bottom:1px solid var(--border);transition:background .15s}.vr tbody tr:hover{background:var(--surface2)}.vr tbody tr.dc{background:rgba(220,38,38,.05)}.vr tbody td{padding:9px 12px;vertical-align:middle}.vr tbody td.r{text-align:right}.vr tbody td.c{text-align:center}
.tm{font-size:11px;font-weight:500;white-space:nowrap}.tp{font-size:10px;color:var(--grey);font-family:var(--font-mono)}.tf{font-size:10px;padding:2px 7px;border-radius:3px;display:inline-block;font-weight:500}.fd{background:var(--merc-dim);color:var(--merc)}.fc{background:var(--mird-dim);color:#b45309}.fp{background:rgba(217,119,6,.12);color:#d97706}
.sp{font-size:9.5px;padding:2px 8px;border-radius:2px;font-weight:600;display:inline-block;letter-spacing:.05em;text-transform:uppercase}.spm{background:var(--merc-dim);color:var(--merc)}.spd{background:var(--mird-dim);color:var(--mird)}
.db{font-size:9px;padding:2px 6px;background:rgba(220,38,38,.12);color:var(--red);border-radius:2px;display:inline-block}
.fb{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:14px}.fn{padding:6px 14px;border-radius:4px;border:1px solid var(--border);background:var(--surface);color:var(--grey2);font-size:11px;font-family:var(--font-mono);cursor:pointer;transition:all .15s}.fn:hover,.fn.a{border-color:var(--merc);color:var(--white);background:var(--merc-dim)}.fn.mb:hover,.fn.mb.a{border-color:var(--mird);color:var(--white);background:var(--mird-dim)}
.fs{flex:1}.cl{font-size:11px;color:var(--grey)}
.vr input[type=text]{padding:6px 12px;border-radius:4px;border:1px solid var(--border);background:var(--surface);color:var(--white);font-size:11px;font-family:var(--font-mono);outline:none;width:220px}.vr input[type=text]:focus{border-color:var(--merc)}.vr input::placeholder{color:var(--grey)}
.vr input[type=date]{padding:5px 10px;border-radius:4px;border:1px solid var(--border);background:var(--surface);color:var(--white);font-size:11px;font-family:var(--font-mono);outline:none}.vr input[type=date]:focus{border-color:var(--merc)}.vr input[type=date]::-webkit-calendar-picker-indicator{filter:invert(0.7)}
.pw{display:flex;align-items:center;gap:10px;padding:8px 12px;background:var(--surface2);border-radius:4px;margin-bottom:4px}.pd{width:8px;height:8px;border-radius:50%;flex-shrink:0}.pn{flex:1;font-size:11px;color:var(--grey2)}.pc{font-size:11px;color:var(--grey);width:30px;text-align:right}.pa{font-size:12px;color:var(--white);font-weight:500;width:75px;text-align:right}.pe{font-size:10px;color:var(--grey);width:35px;text-align:right}
.eb{border:1px solid rgba(217,119,6,.3);background:rgba(217,119,6,.06);border-radius:6px;padding:14px 18px}.eb h4{font-family:var(--font-head);font-size:13px;color:var(--amber);margin-bottom:6px}
.cb{background:var(--surface2);border-bottom:1px solid var(--border);padding:10px 24px;display:flex;align-items:center;gap:14px;flex-wrap:wrap}
.cbl{font-size:10px;color:var(--grey);text-transform:uppercase;letter-spacing:.1em}
.cbb{padding:5px 14px;border-radius:4px;font-size:11px;font-family:var(--font-mono);cursor:pointer;border:1px solid var(--border);background:var(--surface);color:var(--grey);transition:all .15s}
.csep{width:1px;height:20px;background:var(--border);margin:0 4px}
.rbtn{padding:5px 12px;border-radius:4px;font-size:11px;font-family:var(--font-mono);cursor:pointer;border:1px solid var(--border);background:var(--surface);color:var(--grey2);transition:all .15s;display:flex;align-items:center;gap:6px}.rbtn:hover{border-color:var(--merc);color:var(--white)}
.vr footer{text-align:center;padding:28px 24px;color:var(--grey);font-size:10px;letter-spacing:.05em;border-top:1px solid var(--border);margin-top:40px}`;

interface Props {
  hideCommercialTab?: boolean;
  hideInternalLinks?: boolean;
}

export default function ConsumerDashboardClient({
  hideCommercialTab = false,
}: Props) {
  const [cjs, setCjs] = useState(false);
  const [pods, setPods] = useState<string[]>(["Mercato", "Mirdif"]);
  const [vm, setVm] = useState<"consolidated" | "by-machine">("consolidated");
  const [tab, setTab] = useState("overview");
  const [D, setD] = useState<VoxConsumerReport | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [tsf, setTsf] = useState("all");
  const [tff, setTff] = useState("all");
  const [tq, setTq] = useState("");
  const [txnDefaultOnly, setTxnDefaultOnly] = useState(false);
  const [txnPage, setTxnPage] = useState(0);
  const [cq, setCq] = useState(""); // Commercial transaction-detail search
  const PAGE_SIZE = 50;
  const [dateFrom, setDateFrom] = useState("2026-02-06");
  const [dateTo, setDateTo] = useState(new Date().toISOString().split("T")[0]);
  const [lastUpdated, setLastUpdated] = useState<string | null>(null);
  // AC3: Products page machine filter (machine_id, server-side via p_machine).
  const [selectedMachine, setSelectedMachine] = useState<string | null>(null);
  // Full machine list for the dropdown, captured from an unscoped fetch.
  const [allMachines, setAllMachines] = useState<
    { id: string; name: string; site: string }[]
  >([]);

  const isC = vm === "consolidated" && pods.length > 1;

  // Commercial-tab state hoisted up here so the cash-recovery callback below
  // can read C / setC in its dependency array.
  const [C, setC] = useState<VoxCommercialReport | null>(null);
  const [cLoading, setCLoading] = useState(false);
  const [cErr, setCErr] = useState<string | null>(null);

  // ── Cash recovery modal (opens from "+ cash" button on discrepancy rows) ──
  type CashTender =
    | "cash"
    | "card_retry"
    | "bank_transfer"
    | "voucher"
    | "other";
  const [crOpen, setCrOpen] = useState(false);
  const [crTxn, setCrTxn] = useState<{
    psp: string; // full psp_reference (note: row shows short prefix; we look up the full)
    merchant_ref: string; // the full base_txn_sn = adyen merchant_reference
    machine: string;
    date: string;
    time: string;
    total: number;
    adyen_captured: number;
    cash_recovered: number;
    gap: number;
  } | null>(null);
  const [crAmount, setCrAmount] = useState("");
  const [crReason, setCrReason] = useState("");
  const [crTender, setCrTender] = useState<CashTender>("cash");
  const [crCollector, setCrCollector] = useState("");
  const [crSubmitting, setCrSubmitting] = useState(false);
  const [crToast, setCrToast] = useState<{ msg: string; ok: boolean } | null>(
    null,
  );

  const openCashModal = useCallback(
    (t: {
      psp: string;
      merchant_ref: string;
      machine: string;
      date: string;
      time: string;
      total: number;
      adyen_captured: number;
      cash_recovered: number;
      gap: number;
    }) => {
      setCrTxn(t);
      setCrAmount(String(t.gap.toFixed(2))); // pre-fill with the remaining gap
      setCrReason(
        `Adyen captured AED ${t.adyen_captured} (psp ${t.psp}); remaining AED ${t.gap.toFixed(2)} settled in cash on the spot.`,
      );
      setCrTender("cash");
      setCrCollector("");
      setCrOpen(true);
    },
    [],
  );

  const submitCashRecovery = useCallback(async () => {
    if (!crTxn) return;
    const amount = Number(crAmount);
    if (!Number.isFinite(amount) || amount <= 0) {
      setCrToast({ msg: "Amount must be a positive number.", ok: false });
      return;
    }
    if (crReason.trim().length < 5) {
      setCrToast({ msg: "Reason needs at least 5 characters.", ok: false });
      return;
    }
    setCrSubmitting(true);
    try {
      const supabase = createClient();
      const { data, error } = await supabase.rpc("record_cash_recovery", {
        p_merchant_reference: crTxn.merchant_ref,
        p_recovered_amount: amount,
        p_reason: crReason.trim(),
        p_collected_by: crCollector.trim() || null,
        p_tender_method: crTender,
        // p_recovered_at omitted → defaults to now()
        // p_notes omitted
      });
      if (error) throw error;
      const remaining = (data as any)?.reconciliation?.remaining_gap ?? 0;
      const closed = (data as any)?.reconciliation?.closed ?? false;
      setCrToast({
        msg: closed
          ? `Logged AED ${amount.toFixed(2)} ${crTender}. Reconciliation closed ✓`
          : `Logged AED ${amount.toFixed(2)} ${crTender}. Remaining gap: AED ${Number(remaining).toFixed(2)}.`,
        ok: true,
      });
      setCrOpen(false);
      // Refresh transactions to reflect new captured / closed disc state.
      // Refresh consumer always; refresh commercial too if it's loaded.
      const refreshes: Promise<void>[] = [
        fetchVoxConsumerReport(pods, isC, dateFrom, dateTo).then((d) =>
          setD(d),
        ),
      ];
      if (tab === "commercial" || C !== null) {
        refreshes.push(
          fetchVoxCommercialReport(pods, dateFrom, dateTo).then((c) => setC(c)),
        );
      }
      await Promise.all(refreshes);
    } catch (e: any) {
      setCrToast({ msg: `Failed: ${e?.message ?? String(e)}`, ok: false });
    } finally {
      setCrSubmitting(false);
    }
  }, [
    crTxn,
    crAmount,
    crReason,
    crCollector,
    crTender,
    pods,
    isC,
    dateFrom,
    dateTo,
    tab,
    C,
  ]);

  // Auto-dismiss toast after 4s
  useEffect(() => {
    if (!crToast) return;
    const id = setTimeout(() => setCrToast(null), 4000);
    return () => clearTimeout(id);
  }, [crToast]);

  const dailyR = useRef<HTMLCanvasElement>(null),
    wowR = useRef<HTMLCanvasElement>(null),
    dowR = useRef<HTMLCanvasElement>(null),
    hourlyR = useRef<HTMLCanvasElement>(null),
    splitR = useRef<HTMLCanvasElement>(null);
  const mdR = useRef<HTMLCanvasElement>(null),
    miR = useRef<HTMLCanvasElement>(null);
  const bubR = useRef<HTMLCanvasElement>(null),
    pbR = useRef<HTMLCanvasElement>(null);
  const fuR = useRef<HTMLCanvasElement>(null),
    caR = useRef<HTMLCanvasElement>(null),
    waR = useRef<HTMLCanvasElement>(null),
    fsR = useRef<HTMLCanvasElement>(null),
    csR = useRef<HTMLCanvasElement>(null);
  const wfR = useRef<HTMLCanvasElement>(null),
    brR = useRef<HTMLCanvasElement>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const d = await fetchVoxConsumerReport(
        pods,
        isC,
        dateFrom,
        dateTo,
        selectedMachine, // AC3
      );
      setD(d);
      // Capture the full machine list for the dropdown only on unscoped fetches.
      if (!selectedMachine) {
        const seen = new Map<
          string,
          { id: string; name: string; site: string }
        >();
        for (const m of d.machines ?? []) {
          if (m.machine_id && !seen.has(m.machine_id))
            seen.set(m.machine_id, {
              id: m.machine_id,
              name: m.machine,
              site: m.site,
            });
        }
        setAllMachines(
          Array.from(seen.values()).sort(
            (a, b) =>
              a.site.localeCompare(b.site) || a.name.localeCompare(b.name),
          ),
        );
      }
      setLastUpdated(
        new Date().toLocaleTimeString("en-GB", {
          hour: "2-digit",
          minute: "2-digit",
        }),
      );
    } catch (e: any) {
      setErr(e.message);
    } finally {
      setLoading(false);
    }
  }, [pods, vm, dateFrom, dateTo, selectedMachine]);
  useEffect(() => {
    load();
  }, [load]);

  const loadCommercial = useCallback(async () => {
    setCLoading(true);
    setCErr(null);
    try {
      setC(await fetchVoxCommercialReport(pods, dateFrom, dateTo));
    } catch (e: any) {
      setCErr(e.message);
    } finally {
      setCLoading(false);
    }
  }, [pods, dateFrom, dateTo]);
  // AC1 (P1): load the commercial report on mount and whenever (pods, period) change,
  // not only when the Commercial tab opens, so the green ribbon never shows a stale window.
  useEffect(() => {
    loadCommercial();
  }, [loadCommercial]);

  const tog = (p: string) =>
    setPods((v) => {
      if (v.includes(p)) {
        if (v.length === 1) return v;
        return v.filter((x) => x !== p);
      }
      return [...v, p];
    });

  const S = D?.summary,
    ha = S?.has_adyen_data ?? false,
    ts = S?.total_sales ?? 0,
    tc = S?.total_captured ?? 0;
  const dp = ha ? (S?.default_rate?.toFixed(2) ?? "0") : "0";
  const gp = ha ? (S?.default_gap ?? 0) : 0;

  // AC1: the green ribbon binds to the COMMERCIAL waterfall (same source as the cards),
  // so the ribbon and the Commercial cards always tell one story for the same (period, pods).
  const W = C?.waterfall;
  const ribTotal = W ? Number(W.total_amount) : ts;
  const ribCaptured = W
    ? Number(W.captured_amount)
    : (S?.matched_captured ?? 0);
  const ribGap = W ? Number(W.default_amount) : gp;
  const ribDefault = W ? Number(W.default_rate_pct).toFixed(2) : dp;
  const ribMatched = W ? Number(W.matched_txns) : (S?.matched_txns ?? 0);
  const ribTotalTxns = W ? Number(W.txn_count) : (S?.total_txns ?? 0);
  const ribDisc = W
    ? (C?.transactions?.filter((t) => Number(t.default_amount || 0) > 0)
        .length ?? 0)
    : (S?.disc_count ?? 0);

  const bds = useCallback(
    (raw: any[], kf: string, vf: string, keys: any[]) => {
      if (isC) {
        const m: Record<string, number> = {};
        raw.forEach((d) => {
          m[d[kf]] = (m[d[kf]] || 0) + d[vf];
        });
        return [
          {
            label: "Total",
            data: keys.map((k) => m[k] || 0),
            backgroundColor: COMBINED,
            borderColor: COMBINED,
            borderRadius: 3,
          },
        ];
      }
      return pods.map((s) => ({
        label: s,
        data: keys.map((k) => {
          const e = raw.find((d) => d[kf] === k && d.site === s);
          return e ? e[vf] : 0;
        }),
        backgroundColor: VOX_PODS[s]?.color || "#555",
        borderColor: VOX_PODS[s]?.color || "#555",
        borderRadius: 3,
      }));
    },
    [isC, pods],
  );

  useChart(
    dailyR,
    D && cjs && tab === "overview"
      ? (() => {
          const dates = [...new Set(D.daily.map((d) => d.date))].sort();
          return {
            type: "bar",
            data: {
              labels: dates.map((d) => d.slice(5)),
              datasets: bds(D.daily, "date", "amount", dates),
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              plugins: {
                ...PLUG,
                legend: {
                  display: !isC,
                  labels: { color: "#9a948e", boxWidth: 12 },
                },
              },
              scales: {
                x: { grid: { color: GRID } },
                y: { grid: { color: GRID }, beginAtZero: true },
              },
            },
          };
        })()
      : null,
    [D, cjs, pods, tab, vm],
  );

  useChart(
    wowR,
    D && cjs && tab === "overview"
      ? (() => {
          const weeks = [
            ...new Set((D.weekly || []).map((w) => w.week_start)),
          ].sort();
          const labels = weeks.map((w) => {
            const d = new Date(w);
            return `W${String(Math.ceil(((d.getTime() - new Date(d.getFullYear(), 0, 1).getTime()) / 86400000 + 1) / 7)).padStart(2, "0")}`;
          });
          return {
            type: "bar",
            data: {
              labels,
              datasets: bds(D.weekly || [], "week_start", "amount", weeks),
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              plugins: {
                ...PLUG,
                legend: {
                  display: !isC,
                  labels: { color: "#9a948e", boxWidth: 12 },
                },
              },
              scales: {
                x: { grid: { color: GRID } },
                y: { grid: { color: GRID }, beginAtZero: true },
              },
            },
          };
        })()
      : null,
    [D, cjs, pods, tab, vm],
  );

  useChart(
    hourlyR,
    D && cjs && tab === "overview"
      ? (() => {
          const hrs = Array.from({ length: 24 }, (_, i) => i);
          return {
            type: "bar",
            data: {
              labels: hrs.map((h) => `${h}h`),
              datasets: bds(D.hourly, "hour", "amount", hrs as any),
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              plugins: PLUG,
              scales: {
                x: { stacked: true, grid: { color: GRID } },
                y: { stacked: true, grid: { color: GRID }, beginAtZero: true },
              },
            },
          };
        })()
      : null,
    [D, cjs, pods, tab, vm],
  );

  useChart(
    dowR,
    D && cjs && tab === "overview"
      ? (() => {
          const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
          return {
            type: "bar",
            data: { labels: days, datasets: bds(D.dow, "dow", "amount", days) },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              plugins: PLUG,
              scales: {
                x: { stacked: true, grid: { color: GRID } },
                y: { stacked: true, grid: { color: GRID }, beginAtZero: true },
              },
            },
          };
        })()
      : null,
    [D, cjs, pods, tab, vm],
  );

  useChart(
    splitR,
    D && cjs && tab === "overview" && !isC
      ? {
          type: "doughnut",
          data: {
            labels: pods,
            datasets: [
              {
                data: pods.map((s) =>
                  D.machines
                    .filter((m) => m.site === s)
                    .reduce((a, m) => a + m.amount, 0),
                ),
                backgroundColor: pods.map((s) => VOX_PODS[s]?.color || "#555"),
                borderColor: "#ffffff",
                borderWidth: 2,
              },
            ],
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            cutout: "62%",
            plugins: {
              ...PLUG,
              legend: {
                display: true,
                position: "bottom",
                labels: {
                  color: "#9a948e",
                  boxWidth: 10,
                  padding: 10,
                  font: { size: 10 },
                },
              },
            },
          },
        }
      : null,
    [D, cjs, pods, tab, vm],
  );

  useChart(
    mdR,
    D && cjs && tab === "sites"
      ? {
          type: "line",
          data: {
            labels: D.daily
              .filter((d) => d.site === "Mercato")
              .sort((a, b) => a.date.localeCompare(b.date))
              .map((d) => d.date.slice(5)),
            datasets: [
              {
                data: D.daily
                  .filter((d) => d.site === "Mercato")
                  .sort((a, b) => a.date.localeCompare(b.date))
                  .map((d) => d.amount),
                borderColor: MERC,
                backgroundColor: "rgba(59,130,246,0.1)",
                fill: true,
                tension: 0.3,
                pointRadius: 3,
              },
            ],
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: PLUG,
            scales: {
              x: { grid: { color: GRID } },
              y: { grid: { color: GRID }, beginAtZero: true },
            },
          },
        }
      : null,
    [D, cjs, tab],
  );
  useChart(
    miR,
    D && cjs && tab === "sites"
      ? {
          type: "line",
          data: {
            labels: D.daily
              .filter((d) => d.site === "Mirdif")
              .sort((a, b) => a.date.localeCompare(b.date))
              .map((d) => d.date.slice(5)),
            datasets: [
              {
                data: D.daily
                  .filter((d) => d.site === "Mirdif")
                  .sort((a, b) => a.date.localeCompare(b.date))
                  .map((d) => d.amount),
                borderColor: MIRD,
                backgroundColor: "rgba(16,185,129,0.1)",
                fill: true,
                tension: 0.3,
                pointRadius: 3,
              },
            ],
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: PLUG,
            scales: {
              x: { grid: { color: GRID } },
              y: { grid: { color: GRID }, beginAtZero: true },
            },
          },
        }
      : null,
    [D, cjs, tab],
  );

  const gpd = useCallback(() => {
    if (!D) return [];
    const c: Record<
      string,
      { name: string; revenue: number; qty: number; sites: string[] }
    > = {};
    D.products.forEach((x) => {
      if (!c[x.name])
        c[x.name] = { name: x.name, revenue: 0, qty: 0, sites: [] };
      c[x.name].revenue += x.revenue;
      c[x.name].qty += x.qty;
      if (!c[x.name].sites.includes(x.site)) c[x.name].sites.push(x.site);
    });
    return Object.values(c).sort((a, b) => b.revenue - a.revenue);
  }, [D]);

  useChart(
    bubR,
    D && cjs && tab === "products"
      ? (() => {
          const pd = gpd();
          const mx = Math.max(...pd.map((p) => p.revenue), 1);
          return {
            type: "bubble",
            data: {
              datasets: pd.map((p, i) => ({
                label: p.name,
                data: [
                  {
                    x: p.qty,
                    y: p.qty > 0 ? +(p.revenue / p.qty).toFixed(1) : 0,
                    r: Math.max(5, (p.revenue / mx) * 40),
                  },
                ],
                backgroundColor: PROD_COLORS[i % PROD_COLORS.length] + "CC",
                borderColor: PROD_COLORS[i % PROD_COLORS.length],
                borderWidth: 1.5,
              })),
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              plugins: {
                legend: { display: false },
                tooltip: {
                  ...PLUG.tooltip,
                  callbacks: {
                    title: (ctx: any) => ctx[0].dataset.label,
                    label: (ctx: any) => [
                      `Units: ${ctx.parsed.x}`,
                      `Avg: AED ${ctx.parsed.y}`,
                      `Rev: ${aed(pd.find((p) => p.name === ctx.dataset.label)?.revenue || 0)}`,
                    ],
                  },
                },
              },
              scales: {
                x: {
                  grid: { color: GRID },
                  title: {
                    display: true,
                    text: "Units Sold \u2192",
                    color: "#6b6860",
                    font: { size: 10 },
                  },
                  beginAtZero: true,
                },
                y: {
                  grid: { color: GRID },
                  title: {
                    display: true,
                    text: "\u2191 Avg Price (AED)",
                    color: "#6b6860",
                    font: { size: 10 },
                  },
                  beginAtZero: true,
                },
              },
            },
          };
        })()
      : null,
    [D, cjs, tab],
  );
  useChart(
    pbR,
    D && cjs && tab === "products"
      ? (() => {
          const pd = gpd();
          return {
            type: "bar",
            data: {
              labels: pd.map((p) => p.name),
              datasets: [
                {
                  data: pd.map((p) => p.revenue),
                  backgroundColor: PROD_COLORS.slice(0, pd.length),
                  borderRadius: 3,
                },
              ],
            },
            options: {
              indexAxis: "y" as const,
              responsive: true,
              maintainAspectRatio: false,
              plugins: PLUG,
              scales: {
                x: { grid: { color: GRID }, beginAtZero: true },
                y: { grid: { color: GRID }, ticks: { font: { size: 10 } } },
              },
            },
          };
        })()
      : null,
    [D, cjs, tab],
  );

  useChart(
    fuR,
    D && cjs && tab === "payments"
      ? (() => {
          const a: Record<string, { c: number; s: number }> = {};
          D.funding.forEach((f) => {
            if (!a[f.source]) a[f.source] = { c: 0, s: 0 };
            a[f.source].c += f.count;
            a[f.source].s += f.sum;
          });
          const ar = Object.entries(a).sort((x, y) => y[1].s - x[1].s);
          const t = ar.reduce((s, [, d]) => s + d.s, 0);
          return {
            type: "doughnut",
            data: {
              labels: ar.map(([k]) => k),
              datasets: [
                {
                  data: ar.map(([, v]) => v.s),
                  backgroundColor: ar.map(([k]) => FUND_COLORS[k] || "#555"),
                  borderColor: "#ffffff",
                  borderWidth: 2,
                },
              ],
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              cutout: "62%",
              plugins: {
                ...PLUG,
                legend: {
                  display: true,
                  position: "bottom",
                  labels: {
                    color: "#9a948e",
                    boxWidth: 10,
                    padding: 10,
                    font: { size: 10 },
                  },
                },
                tooltip: {
                  callbacks: {
                    label: (ctx: any) =>
                      ` AED ${ctx.parsed.toFixed(0)} (${((ctx.parsed / t) * 100).toFixed(0)}%)`,
                  },
                },
              },
            },
          };
        })()
      : null,
    [D, cjs, tab],
  );
  useChart(
    caR,
    D && cjs && tab === "payments"
      ? (() => {
          const a: Record<string, { c: number; s: number }> = {};
          D.cards.forEach((c) => {
            if (!a[c.method]) a[c.method] = { c: 0, s: 0 };
            a[c.method].c += c.count;
            a[c.method].s += c.sum;
          });
          const ar = Object.entries(a).sort((x, y) => y[1].s - x[1].s);
          const t = ar.reduce((s, [, d]) => s + d.s, 0);
          return {
            type: "doughnut",
            data: {
              labels: ar.map(([k]) => k),
              datasets: [
                {
                  data: ar.map(([, v]) => v.s),
                  backgroundColor: ar.map(([k]) => CARD_COLORS[k] || "#555"),
                  borderColor: "#ffffff",
                  borderWidth: 2,
                },
              ],
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              cutout: "62%",
              plugins: {
                ...PLUG,
                legend: {
                  display: true,
                  position: "bottom",
                  labels: {
                    color: "#9a948e",
                    boxWidth: 10,
                    padding: 10,
                    font: { size: 10 },
                  },
                },
                tooltip: {
                  callbacks: {
                    label: (ctx: any) =>
                      ` AED ${ctx.parsed.toFixed(0)} (${((ctx.parsed / t) * 100).toFixed(0)}%)`,
                  },
                },
              },
            },
          };
        })()
      : null,
    [D, cjs, tab],
  );
  useChart(
    waR,
    D && cjs && tab === "payments"
      ? (() => {
          const ar = [...D.wallets].sort((a, b) => b.sum - a.sum);
          const t = ar.reduce((s, w) => s + w.sum, 0);
          return {
            type: "doughnut",
            data: {
              labels: ar.map((w) => WALLET_NAMES[w.variant] || w.variant),
              datasets: [
                {
                  data: ar.map((w) => w.sum),
                  backgroundColor: PROD_COLORS.slice(0, ar.length),
                  borderColor: "#ffffff",
                  borderWidth: 2,
                },
              ],
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              cutout: "62%",
              plugins: {
                ...PLUG,
                legend: {
                  display: true,
                  position: "bottom",
                  labels: {
                    color: "#9a948e",
                    boxWidth: 10,
                    padding: 10,
                    font: { size: 10 },
                  },
                },
                tooltip: {
                  callbacks: {
                    label: (ctx: any) =>
                      ` AED ${ctx.parsed.toFixed(0)} (${((ctx.parsed / t) * 100).toFixed(0)}%)`,
                  },
                },
              },
            },
          };
        })()
      : null,
    [D, cjs, tab],
  );
  useChart(
    fsR,
    D && cjs && tab === "payments"
      ? (() => {
          const bs: Record<string, Record<string, number>> = {};
          D.funding.forEach((r) => {
            if (!bs[r.source]) bs[r.source] = {};
            bs[r.source][r.site] = r.sum;
          });
          return {
            type: "bar",
            data: {
              labels: pods,
              datasets: ["DEBIT", "CREDIT", "PREPAID"].map((f) => ({
                label: f,
                data: pods.map((s) => bs[f]?.[s] || 0),
                backgroundColor: FUND_COLORS[f],
                borderRadius: 3,
              })),
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              plugins: {
                ...PLUG,
                legend: {
                  display: true,
                  labels: { color: "#9a948e", boxWidth: 12 },
                },
              },
              scales: {
                x: { grid: { color: GRID }, stacked: true },
                y: { grid: { color: GRID }, beginAtZero: true, stacked: true },
              },
            },
          };
        })()
      : null,
    [D, cjs, tab, pods],
  );
  useChart(
    csR,
    D && cjs && tab === "payments"
      ? (() => {
          const bs: Record<string, Record<string, number>> = {};
          D.cards.forEach((r) => {
            if (!bs[r.method]) bs[r.method] = {};
            bs[r.method][r.site] = r.sum;
          });
          return {
            type: "bar",
            data: {
              labels: pods,
              datasets: ["Visa", "Mastercard"].map((c) => ({
                label: c,
                data: pods.map((s) => bs[c]?.[s] || 0),
                backgroundColor: CARD_COLORS[c],
                borderRadius: 3,
              })),
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              plugins: {
                ...PLUG,
                legend: {
                  display: true,
                  labels: { color: "#9a948e", boxWidth: 12 },
                },
              },
              scales: {
                x: { grid: { color: GRID } },
                y: { grid: { color: GRID }, beginAtZero: true },
              },
            },
          };
        })()
      : null,
    [D, cjs, tab, pods],
  );

  // Commercial waterfall chart
  useChart(
    wfR,
    C && cjs && tab === "commercial"
      ? (() => {
          const w = C.waterfall;
          const num = (v: number) => (v == null || isNaN(v) ? 0 : Number(v));
          const total = num(w.total_amount);
          const captured = num(w.captured_amount);
          const refund = num(w.refund_amount);
          const adyenFees = num(w.adyen_fees);
          const netRev = num(w.net_revenue);
          const boonzShare = num(w.boonz_share);
          const voxShare = num(w.vox_share);
          const boonzCogs = num(w.boonz_cogs);
          const voxNetDues = num(w.vox_net_dues);
          const bars = [
            {
              label: ["Total", "Amount"],
              base: 0,
              top: total,
              color: "#2A3547",
              displayVal: total,
            },
            {
              label: ["Default"],
              base: captured,
              top: total,
              color: "#EF4444",
              displayVal: num(w.default_amount),
            },
            {
              label: ["Captured"],
              base: 0,
              top: captured,
              color: "#0F4D3A",
              displayVal: captured,
            },
            {
              label: ["Refund"],
              base: captured - refund,
              top: captured,
              color: "#EC4899",
              displayVal: refund,
            },
            {
              label: ["Adyen", "Fees"],
              base: captured - refund - adyenFees,
              top: captured - refund,
              color: "#F97316",
              displayVal: adyenFees,
            },
            {
              label: ["Net", "Revenue"],
              base: 0,
              top: netRev,
              color: "#0E3F4D",
              displayVal: netRev,
            },
            {
              label: ["Boonz", "20%"],
              base: 0,
              top: boonzShare,
              color: "#F59E0B",
              displayVal: boonzShare,
            },
            {
              label: ["VOX", "80%"],
              base: 0,
              top: voxShare,
              color: "#3D2F63",
              displayVal: voxShare,
            },
            {
              label: ["Boonz", "COGS"],
              base: voxShare - boonzCogs,
              top: voxShare,
              color: "#EF4444",
              displayVal: boonzCogs,
            },
            {
              label: ["VOX", "Net Dues"],
              base: 0,
              top: voxNetDues,
              color: "#8B5CF6",
              displayVal: voxNetDues,
            },
          ];
          const maxVal = Math.max(...bars.map((b) => b.top)) * 1.15;
          return {
            type: "bar",
            data: {
              labels: bars.map((b) => b.label),
              datasets: [
                {
                  data: bars.map((b) => [b.base, b.top]),
                  backgroundColor: bars.map((b) => b.color),
                  borderWidth: 0,
                  borderRadius: 4,
                  barPercentage: 0.72,
                  categoryPercentage: 0.85,
                },
              ],
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              plugins: {
                legend: { display: false },
                tooltip: {
                  ...PLUG.tooltip,
                  callbacks: {
                    title: (ctx: any) => {
                      const l = bars[ctx[0].dataIndex].label;
                      return Array.isArray(l) ? l.join(" ") : l;
                    },
                    label: (ctx: any) =>
                      ` AED ${bars[ctx.dataIndex].displayVal.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
                  },
                },
              },
              scales: {
                x: {
                  grid: { display: false },
                  ticks: { color: "#9a948e", font: { size: 10 } },
                },
                y: {
                  grid: { color: GRID },
                  ticks: {
                    color: "#6b6860",
                    font: { size: 10 },
                    callback: (v: any) => `${(v / 1000).toFixed(1)}k`,
                  },
                  beginAtZero: true,
                  max: maxVal,
                },
              },
              animation: { duration: 500 },
            },
          };
        })()
      : null,
    [C, cjs, tab],
  );

  // Boonz Receipts doughnut
  useChart(
    brR,
    C && cjs && tab === "commercial"
      ? {
          type: "doughnut",
          data: {
            labels: ["Boonz 20% Share", "COGS Reimbursement"],
            datasets: [
              {
                data: [
                  Number(C.waterfall.boonz_share || 0),
                  Number(C.waterfall.boonz_cogs || 0),
                ],
                backgroundColor: ["#F59E0B", "#EF4444"],
                borderColor: "#ffffff",
                borderWidth: 3,
              },
            ],
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            cutout: "62%",
            plugins: {
              ...PLUG,
              legend: {
                display: true,
                position: "bottom",
                labels: {
                  color: "#9a948e",
                  boxWidth: 10,
                  padding: 10,
                  font: { size: 10 },
                },
              },
              tooltip: {
                ...PLUG.tooltip,
                callbacks: {
                  label: (ctx: any) =>
                    ` ${ctx.label}: AED ${ctx.parsed.toLocaleString(undefined, { minimumFractionDigits: 2 })}`,
                },
              },
            },
          },
        }
      : null,
    [C, cjs, tab],
  );

  const ft = D
    ? D.transactions.filter((t) => {
        if (tsf !== "all" && t.site !== tsf) return false;
        if (tff !== "all" && t.funding.toUpperCase() !== tff) return false;
        if (txnDefaultOnly && !t.disc) return false;
        if (tq && !JSON.stringify(t).toLowerCase().includes(tq.toLowerCase()))
          return false;
        return true;
      })
    : [];
  const totalPages = Math.ceil(ft.length / PAGE_SIZE);
  const pageRows = ft.slice(txnPage * PAGE_SIZE, (txnPage + 1) * PAGE_SIZE);
  const tabs = [
    { id: "overview", l: "Overview" },
    { id: "sites", l: "Sites & Machines" },
    { id: "products", l: "Products" },
    { id: "payments", l: "Payments" },
    { id: "transactions", l: "Transactions" },
    ...(!hideCommercialTab ? [{ id: "commercial", l: "Commercial" }] : []),
  ];

  return (
    <>
      <Script
        src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"
        onLoad={() => setCjs(true)}
      />
      <style dangerouslySetInnerHTML={{ __html: CSS }} />
      <div className="vr">
        <nav>
          <div className="nb">MAFE</div>
          {tabs.map((t) => (
            <div
              key={t.id}
              className={`nt ${tab === t.id ? "a" : ""}`}
              onClick={() => setTab(t.id)}
            >
              {t.l}
            </div>
          ))}
          <div className="nm">
            <span className="sb sbm">Mercato</span>
            <span className="sb sbi">Mirdif</span>
          </div>
        </nav>

        <div className="cb">
          <span className="cbl">Period</span>
          <input
            type="date"
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
            max={dateTo}
          />
          <span style={{ color: "#6b6860", fontSize: 11 }}>to</span>
          <input
            type="date"
            value={dateTo}
            onChange={(e) => setDateTo(e.target.value)}
            min={dateFrom}
          />
          <div className="csep" />
          <span className="cbl">Pods</span>
          {Object.entries(VOX_PODS).map(([n, p]) => (
            <button
              key={n}
              className="cbb"
              style={
                pods.includes(n)
                  ? {
                      borderColor: p.color,
                      color: p.color,
                      background: `${p.color}18`,
                    }
                  : {}
              }
              onClick={() => tog(n)}
            >
              {pods.includes(n) ? "\u2713 " : ""}
              {n}
            </button>
          ))}
          <div className="csep" />
          <span className="cbl">View</span>
          {(["consolidated", "by-machine"] as const).map((m) => (
            <button
              key={m}
              className="cbb"
              style={
                vm === m
                  ? {
                      borderColor: "#F59E0B",
                      color: "#F59E0B",
                      background: "rgba(245,158,11,0.12)",
                    }
                  : {}
              }
              onClick={() => setVm(m)}
            >
              {m === "consolidated" ? "Consolidated" : "By Machine"}
            </button>
          ))}
          <div className="csep" />
          <button className="rbtn" onClick={load} disabled={loading}>
            <span style={{ fontSize: 14, lineHeight: 1 }}>
              {loading ? "\u23F3" : "\u21BB"}
            </span>
            Refresh
          </button>
          {lastUpdated && (
            <span style={{ fontSize: 10, color: "#6b6860" }}>
              Last: {lastUpdated}
            </span>
          )}
          {loading && (
            <span
              style={{ fontSize: 10, color: "#F59E0B", marginLeft: "auto" }}
            >
              Loading&hellip;
            </span>
          )}
        </div>

        {D && !ha && (
          <div
            style={{
              background: "rgba(245,158,11,0.06)",
              borderBottom: "1px solid rgba(245,158,11,0.2)",
              padding: "8px 24px",
              fontSize: 11,
              color: "#F59E0B",
            }}
          >
            <strong>{"\u26A0"} Adyen not loaded</strong>{" "}
            <span style={{ color: "#9a948e" }}>
              {"\u2014"} Payment columns show {"\u201C\u2014\u201D"} until
              adyen_transactions updated.
            </span>
          </div>
        )}
        {(W || (D && ha)) && (
          <div
            style={{
              background: "#24544a",
              borderBottom: "1px solid #1d4439",
              padding: "9px 24px",
              display: "flex",
              alignItems: "center",
              gap: 24,
              fontSize: 11,
              flexWrap: "wrap",
            }}
          >
            <span
              style={{
                color: "rgba(255,255,255,0.7)",
                textTransform: "uppercase",
                letterSpacing: ".1em",
                fontSize: 10,
              }}
            >
              Payment Default
            </span>
            <span style={{ color: "rgba(255,255,255,0.8)" }}>
              Total{" "}
              <strong style={{ color: "#ffffff" }}>{aed(ribTotal)}</strong>
            </span>
            <span style={{ color: "rgba(255,255,255,0.3)" }}>|</span>
            <span style={{ color: "rgba(255,255,255,0.8)" }}>
              Captured{" "}
              <strong style={{ color: "#a7f3d0" }}>{aed(ribCaptured)}</strong>
            </span>
            <span style={{ color: "rgba(255,255,255,0.3)" }}>|</span>
            <span style={{ color: "rgba(255,255,255,0.8)" }}>
              Gap <strong style={{ color: "#fca5a5" }}>{aed(ribGap)}</strong>
            </span>
            <span style={{ color: "rgba(255,255,255,0.3)" }}>|</span>
            <span style={{ color: "rgba(255,255,255,0.8)" }}>
              Default{" "}
              <strong style={{ color: "#fde68a", fontSize: 14 }}>
                {ribDefault}%
              </strong>
            </span>
            <span style={{ color: "rgba(255,255,255,0.3)" }}>|</span>
            <span style={{ color: "rgba(255,255,255,0.6)", fontSize: 10 }}>
              {ribDisc} discrepancies {"\u00B7"} {ribMatched}/{ribTotalTxns}{" "}
              matched
            </span>
          </div>
        )}

        {err && (
          <div style={{ padding: 24, textAlign: "center", color: "#EF4444" }}>
            Failed: {err}
            <br />
            <button
              onClick={load}
              style={{
                marginTop: 8,
                padding: "6px 16px",
                background: "#e8e4de",
                border: "1px solid #EF4444",
                color: "#EF4444",
                borderRadius: 4,
                cursor: "pointer",
              }}
            >
              Retry
            </button>
          </div>
        )}
        {loading && !D && (
          <div style={{ padding: 60, textAlign: "center", color: "#6b6860" }}>
            Loading&hellip;
          </div>
        )}

        {D && (
          <>
            {tab === "overview" && (
              <div className="pg">
                <div style={{ marginBottom: 24 }}>
                  <div className="sl">
                    {S!.date_from} to {S!.date_to} {"\u00B7"}{" "}
                    {isC ? "Consolidated" : pods.join(" + ")}
                  </div>
                  <h2>MAFE {"\u2014"} Consumer Report</h2>
                </div>
                <div className="sr">
                  {(isC
                    ? [
                        {
                          l: "Total Revenue",
                          v: aed(ts),
                          c: "kc",
                          vc: "vc",
                          s: `${S!.total_txns} txns \u00B7 ${S!.total_units} units`,
                        },
                        {
                          l: "Machines",
                          v: String(S!.num_machines),
                          c: "ka",
                          vc: "va",
                          s: `${[...new Set(D.products.map((p) => p.name))].length} products`,
                        },
                        {
                          l: "Default",
                          v: `${dp}%`,
                          c: ha ? "kr" : "ka",
                          vc: ha ? "vr2" : "va",
                          s: ha
                            ? `${S?.disc_count ?? 0} disc \u00B7 Gap ${aed(gp)}`
                            : "Pending Adyen",
                        },
                      ]
                    : [
                        {
                          l: "Total Revenue",
                          v: aed(ts),
                          c: "kc",
                          vc: "vc",
                          s: `${S!.total_txns} txns`,
                        },
                        {
                          l: "Mercato",
                          v: aed(S!.mercato.total),
                          c: "km",
                          vc: "vm",
                          s: `${S!.mercato.txns} txns \u00B7 ${S!.mercato.units} units`,
                        },
                        {
                          l: "Mirdif",
                          v: aed(S!.mirdif.total),
                          c: "ki",
                          vc: "vi",
                          s: `${S!.mirdif.txns} txns \u00B7 ${S!.mirdif.units} units`,
                        },
                        {
                          l: "Units",
                          v: String(S!.total_units),
                          c: "ka",
                          vc: "va",
                          s: `${S!.num_machines} machines`,
                        },
                        {
                          l: "Default",
                          v: `${dp}%`,
                          c: ha ? "kr" : "ka",
                          vc: ha ? "vr2" : "va",
                          s: ha
                            ? `${S?.disc_count ?? 0} disc \u00B7 Gap ${aed(gp)}`
                            : "Pending",
                        },
                        {
                          l: "Adyen",
                          v: `${S!.adyen_match_pct}%`,
                          c: ha ? "ki" : "kr",
                          vc: ha ? "vi" : "vr2",
                          s: ha ? "Linked" : "Pending",
                        },
                      ]
                  ).map((k, i) => (
                    <div key={i} className={`kp ${k.c}`}>
                      <div className="kl">{k.l}</div>
                      <div className={`kv ${k.vc}`}>{k.v}</div>
                      <div className="ks">{k.s}</div>
                    </div>
                  ))}
                </div>
                <div className="gr g2" style={{ marginBottom: 14 }}>
                  <div className="cd">
                    <div className="sl">Daily Revenue</div>
                    {!isC && (
                      <div className="lg">
                        {pods.map((s) => (
                          <div key={s} className="li">
                            <div
                              className="ld"
                              style={{ background: VOX_PODS[s]?.color }}
                            />
                            {s}
                          </div>
                        ))}
                      </div>
                    )}
                    <div className="cw" style={{ height: 200 }}>
                      <canvas ref={dailyR} />
                    </div>
                  </div>
                  <div className="cd">
                    <div className="sl">Week-on-Week Revenue</div>
                    <div className="cw" style={{ height: 220 }}>
                      <canvas ref={wowR} />
                    </div>
                  </div>
                </div>
                <div className="gr g3">
                  <div className="cd">
                    <div className="sl">Hourly</div>
                    <div className="cw" style={{ height: 170 }}>
                      <canvas ref={hourlyR} />
                    </div>
                  </div>
                  <div className="cd">
                    <div className="sl">Day of Week</div>
                    <div className="cw" style={{ height: 170 }}>
                      <canvas ref={dowR} />
                    </div>
                  </div>
                  {!isC ? (
                    <div className="cd">
                      <div className="sl">Site Split</div>
                      <div className="cw" style={{ height: 170 }}>
                        <canvas ref={splitR} />
                      </div>
                    </div>
                  ) : (
                    <div className="cd">
                      <div className="sl">Data Coverage</div>
                      <div style={{ padding: "20px 0" }}>
                        <div className="pr">
                          <span className="pl">Weimi (Sales)</span>
                          <div className="pb">
                            <div
                              className="pf"
                              style={{ width: "100%", background: MIRD }}
                            />
                          </div>
                          <span className="pv" style={{ color: MIRD }}>
                            Live
                          </span>
                        </div>
                        <div className="pr">
                          <span className="pl">Adyen (Payments)</span>
                          <div className="pb">
                            <div
                              className="pf"
                              style={{
                                width: `${S!.adyen_match_pct}%`,
                                background: ha ? MERC : "#EF4444",
                              }}
                            />
                          </div>
                          <span className="pv">{S!.adyen_match_pct}%</span>
                        </div>
                      </div>
                    </div>
                  )}
                </div>
              </div>
            )}

            {tab === "sites" && (
              <div className="pg">
                <div style={{ marginBottom: 20 }}>
                  <div className="sl">By Location</div>
                  <h2>Sites &amp; Machine Performance</h2>
                </div>
                <div className="ss">
                  {pods.map((s) => {
                    const sm = s === "Mercato" ? S!.mercato : S!.mirdif;
                    const p = VOX_PODS[s];
                    return (
                      <div
                        key={s}
                        className={`si ${s === "Mercato" ? "sm" : "sd"}`}
                      >
                        <div>
                          <div
                            className={`sn ${s === "Mercato" ? "snm" : "sni"}`}
                          >
                            {s.toUpperCase()} {"\u2014"} {p.label}
                          </div>
                          <div
                            style={{
                              fontSize: 10,
                              color: "var(--grey)",
                              marginTop: 2,
                            }}
                          >
                            Since {p.inception}
                          </div>
                        </div>
                        <div className="st">
                          <span>
                            Rev <strong>{aed(sm.total)}</strong>
                          </span>
                          <span>
                            Txns <strong>{sm.txns}</strong>
                          </span>
                          <span>
                            Units <strong>{sm.units}</strong>
                          </span>
                        </div>
                      </div>
                    );
                  })}
                </div>
                <div className="gr g2" style={{ marginBottom: 14 }}>
                  {pods.map((s) => {
                    const ms = D.machines.filter((m) => m.site === s);
                    const st2 = ms.reduce((a, m) => a + m.amount, 0);
                    const p = VOX_PODS[s];
                    const cr = s === "Mercato" ? mdR : miR;
                    return (
                      <div
                        key={s}
                        className="cd"
                        style={{ display: "flex", flexDirection: "column" }}
                      >
                        <h3>
                          {s} {"\u2014"} Performance
                        </h3>
                        <div style={{ marginBottom: 16 }}>
                          <div className="sl" style={{ marginBottom: 10 }}>
                            Daily trend
                          </div>
                          <div className="cw" style={{ height: 140 }}>
                            <canvas ref={cr} />
                          </div>
                        </div>
                        <div style={{ marginTop: "auto" }}>
                          <div className="sl" style={{ marginBottom: 8 }}>
                            Machine Breakdown
                          </div>
                          {ms.map((m) => (
                            <div key={m.machine} className="pr">
                              <span className="pl">
                                {MACHINE_LABELS[m.machine] ||
                                  shortMachine(m.machine)}
                              </span>
                              <div className="pb">
                                <div
                                  className="pf"
                                  style={{
                                    width: `${st2 > 0 ? (m.amount / st2) * 100 : 0}%`,
                                    background: p.color,
                                  }}
                                />
                              </div>
                              <span className="pv">{aed(m.amount)}</span>
                              <span className="pp">{pct(m.amount, st2)}</span>
                            </div>
                          ))}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}

            {tab === "products" && (
              <div className="pg">
                <div style={{ marginBottom: 20 }}>
                  <div className="sl">Catalogue Performance</div>
                  <h2>Product Analysis</h2>
                  <p
                    style={{ color: "var(--grey)", fontSize: 11, marginTop: 4 }}
                  >
                    Filtered by:{" "}
                    {isC ? "All pods (consolidated)" : pods.join(" + ")}
                  </p>
                  {/* AC3: machine filter, server-side scope via p_machine */}
                  <div
                    style={{
                      marginTop: 10,
                      display: "flex",
                      alignItems: "center",
                      gap: 8,
                    }}
                  >
                    <label
                      style={{
                        fontSize: 11,
                        color: "var(--grey)",
                        fontFamily: "var(--font-mono)",
                      }}
                    >
                      Machine
                    </label>
                    <select
                      value={selectedMachine ?? ""}
                      onChange={(e) =>
                        setSelectedMachine(e.target.value || null)
                      }
                      style={{
                        padding: "6px 10px",
                        borderRadius: 4,
                        border: "1px solid var(--border)",
                        background: "var(--surface)",
                        color: "var(--white)",
                        fontSize: 11,
                        fontFamily: "var(--font-mono)",
                        outline: "none",
                        minWidth: 240,
                      }}
                    >
                      <option value="">All machines</option>
                      {["Mercato", "Mirdif"].map((site) => {
                        const opts = allMachines.filter((m) => m.site === site);
                        if (!opts.length) return null;
                        return (
                          <optgroup key={site} label={site}>
                            {opts.map((m) => (
                              <option key={m.id} value={m.id}>
                                {m.name}
                              </option>
                            ))}
                          </optgroup>
                        );
                      })}
                    </select>
                  </div>
                </div>
                <div className="gr g2" style={{ marginBottom: 14 }}>
                  <div className="cd">
                    <div className="sl">Volume vs Value</div>
                    <p
                      style={{
                        fontSize: 10,
                        color: "var(--grey)",
                        marginBottom: 8,
                      }}
                    >
                      Bubble = revenue {"\u00B7"} X = units {"\u00B7"} Y = avg
                      price
                    </p>
                    <div className="cw" style={{ height: 300 }}>
                      <canvas ref={bubR} />
                    </div>
                  </div>
                  <div className="cd">
                    <div className="sl">Revenue by Product</div>
                    <div className="cw" style={{ height: 300 }}>
                      <canvas ref={pbR} />
                    </div>
                  </div>
                </div>
                <div className="cd">
                  <div className="sl">Product Detail</div>
                  <div className="tw">
                    <table>
                      <thead>
                        <tr>
                          <th>Product</th>
                          <th>Site</th>
                          <th className="r">Revenue</th>
                          <th className="r">Units</th>
                          <th className="r">Avg Price</th>
                          <th>Share</th>
                        </tr>
                      </thead>
                      <tbody>
                        {gpd().map((p) => {
                          const tot = gpd().reduce((s, x) => s + x.revenue, 0);
                          const sh =
                            tot > 0
                              ? ((p.revenue / tot) * 100).toFixed(0)
                              : "0";
                          return (
                            <tr key={p.name}>
                              <td style={{ fontWeight: 500 }}>{p.name}</td>
                              <td>
                                {[...new Set(p.sites)].map((s) => (
                                  <span
                                    key={s}
                                    className={`sp ${s === "Mercato" ? "spm" : "spd"}`}
                                    style={{ marginRight: 4 }}
                                  >
                                    {s}
                                  </span>
                                ))}
                              </td>
                              <td
                                className="r"
                                style={{ fontWeight: 600, color: "#0a0a0a" }}
                              >
                                {aed(p.revenue)}
                              </td>
                              <td className="r">{p.qty}</td>
                              <td className="r">
                                AED {(p.revenue / (p.qty || 1)).toFixed(0)}
                              </td>
                              <td>
                                <div
                                  style={{
                                    display: "flex",
                                    alignItems: "center",
                                    gap: 8,
                                  }}
                                >
                                  <div
                                    style={{
                                      flex: 1,
                                      height: 6,
                                      background: "#e8e4de",
                                      borderRadius: 2,
                                      overflow: "hidden",
                                    }}
                                  >
                                    <div
                                      style={{
                                        width: `${sh}%`,
                                        height: "100%",
                                        background: PROD_COLORS[0],
                                        borderRadius: 2,
                                      }}
                                    />
                                  </div>
                                  <span
                                    style={{
                                      fontSize: 10,
                                      color: "#9a948e",
                                      minWidth: 28,
                                    }}
                                  >
                                    {sh}%
                                  </span>
                                </div>
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            )}
            {tab === "payments" && (
              <div className="pg">
                <div style={{ marginBottom: 20 }}>
                  <div className="sl">Payment Intelligence</div>
                  <h2>Payment Method Breakdown</h2>
                  {!ha && (
                    <p style={{ color: "#F59E0B", fontSize: 11, marginTop: 8 }}>
                      {"\u26A0"} Pending Adyen import
                    </p>
                  )}
                </div>
                <div className="gr g3" style={{ marginBottom: 14 }}>
                  <div className="cd">
                    <div className="sl">Funding Source</div>
                    <div className="cw" style={{ height: 200 }}>
                      <canvas ref={fuR} />
                    </div>
                    <div style={{ marginTop: 12 }}>
                      {(() => {
                        const a: Record<string, { c: number; s: number }> = {};
                        D.funding.forEach((f) => {
                          if (!a[f.source]) a[f.source] = { c: 0, s: 0 };
                          a[f.source].c += f.count;
                          a[f.source].s += f.sum;
                        });
                        const ar = Object.entries(a).sort(
                          (x, y) => y[1].s - x[1].s,
                        );
                        const t = ar.reduce((s, [, d]) => s + d.s, 0);
                        return ar.map(([k, v]) => (
                          <div key={k} className="pw">
                            <div
                              className="pd"
                              style={{ background: FUND_COLORS[k] || "#555" }}
                            />
                            <div className="pn">{k}</div>
                            <div className="pc">
                              {v.c}
                              {"\u00D7"}
                            </div>
                            <div className="pa">{aed(v.s)}</div>
                            <div className="pe">{pct(v.s, t)}</div>
                          </div>
                        ));
                      })()}
                    </div>
                  </div>
                  <div className="cd">
                    <div className="sl">Card Network</div>
                    <div className="cw" style={{ height: 200 }}>
                      <canvas ref={caR} />
                    </div>
                    <div style={{ marginTop: 12 }}>
                      {(() => {
                        const a: Record<string, { c: number; s: number }> = {};
                        D.cards.forEach((c2) => {
                          if (!a[c2.method]) a[c2.method] = { c: 0, s: 0 };
                          a[c2.method].c += c2.count;
                          a[c2.method].s += c2.sum;
                        });
                        const ar = Object.entries(a).sort(
                          (x, y) => y[1].s - x[1].s,
                        );
                        const t = ar.reduce((s, [, d]) => s + d.s, 0);
                        return ar.map(([k, v]) => (
                          <div key={k} className="pw">
                            <div
                              className="pd"
                              style={{ background: CARD_COLORS[k] || "#555" }}
                            />
                            <div className="pn">{k}</div>
                            <div className="pc">
                              {v.c}
                              {"\u00D7"}
                            </div>
                            <div className="pa">{aed(v.s)}</div>
                            <div className="pe">{pct(v.s, t)}</div>
                          </div>
                        ));
                      })()}
                    </div>
                  </div>
                  <div className="cd">
                    <div className="sl">Digital Wallet</div>
                    <div className="cw" style={{ height: 200 }}>
                      <canvas ref={waR} />
                    </div>
                    <div style={{ marginTop: 12 }}>
                      {[...D.wallets]
                        .sort((a2, b) => b.sum - a2.sum)
                        .map((w, i) => {
                          const t = D.wallets.reduce((s, x) => s + x.sum, 0);
                          return (
                            <div key={w.variant} className="pw">
                              <div
                                className="pd"
                                style={{ background: PROD_COLORS[i] }}
                              />
                              <div className="pn">
                                {WALLET_NAMES[w.variant] || w.variant}
                              </div>
                              <div className="pc">
                                {w.count}
                                {"\u00D7"}
                              </div>
                              <div className="pa">{aed(w.sum)}</div>
                              <div className="pe">{pct(w.sum, t)}</div>
                            </div>
                          );
                        })}
                    </div>
                  </div>
                </div>
                <div className="gr g2">
                  <div className="cd">
                    <div className="sl">Funding by Site</div>
                    <div className="cw" style={{ height: 200 }}>
                      <canvas ref={fsR} />
                    </div>
                  </div>
                  <div className="cd">
                    <div className="sl">Cards by Site</div>
                    <div className="cw" style={{ height: 200 }}>
                      <canvas ref={csR} />
                    </div>
                  </div>
                </div>
              </div>
            )}

            {tab === "transactions" && (
              <div className="pg">
                <div style={{ marginBottom: 16 }}>
                  <div className="sl">Full Ledger</div>
                  <h2>Transaction Detail</h2>
                  <p
                    style={{ color: "var(--grey)", fontSize: 12, marginTop: 4 }}
                  >
                    {D.transactions.length} txns
                    {!ha && " \u00B7 payment cols pending Adyen"}
                  </p>
                </div>
                {(S?.disc_count ?? 0) > 0 && (
                  <div
                    className="cd"
                    style={{
                      marginBottom: 14,
                      background: "rgba(239,68,68,0.06)",
                      borderColor: "rgba(239,68,68,0.3)",
                    }}
                  >
                    <span style={{ color: "var(--red)", fontWeight: 600 }}>
                      {"\u26A0"} {S?.disc_count}{" "}
                      {S?.disc_count === 1 ? "Discrepancy" : "Discrepancies"}
                    </span>
                  </div>
                )}
                <div className="fb">
                  {["all", ...pods].map((s) => (
                    <button
                      key={s}
                      className={`fn ${s === "Mirdif" ? "mb" : ""} ${tsf === s ? "a" : ""}`}
                      onClick={() => {
                        setTsf(s);
                        setTxnPage(0);
                      }}
                    >
                      {s === "all" ? "All Sites" : s}
                    </button>
                  ))}
                  {["all", "DEBIT", "CREDIT", "PREPAID"].map((f) => (
                    <button
                      key={f}
                      className={`fn ${tff === f && !txnDefaultOnly ? "a" : ""}`}
                      onClick={() => {
                        setTff(f);
                        setTxnDefaultOnly(false);
                        setTxnPage(0);
                      }}
                    >
                      {f === "all"
                        ? "All Funding"
                        : f.charAt(0) + f.slice(1).toLowerCase()}
                    </button>
                  ))}
                  <button
                    className={`fn ${txnDefaultOnly ? "a" : ""}`}
                    onClick={() => {
                      setTxnDefaultOnly(!txnDefaultOnly);
                      setTff("all");
                      setTxnPage(0);
                    }}
                  >
                    Default
                  </button>
                  <div className="fs" />
                  <input
                    type="text"
                    placeholder="Search&hellip;"
                    value={tq}
                    onChange={(e) => {
                      setTq(e.target.value);
                      setTxnPage(0);
                    }}
                  />
                  <span className="cl">
                    Showing {ft.length > 0 ? txnPage * PAGE_SIZE + 1 : 0}&ndash;
                    {Math.min((txnPage + 1) * PAGE_SIZE, ft.length)} of{" "}
                    {ft.length}
                  </span>
                </div>
                <div className="tw">
                  <table>
                    <thead>
                      <tr>
                        <th>Date</th>
                        <th>Time</th>
                        <th>Machine</th>
                        <th>Site</th>
                        <th>PSP</th>
                        <th className="c">Fund</th>
                        <th className="c">Card</th>
                        <th className="c">Wallet</th>
                        <th className="r">Total</th>
                        <th className="r">Captured</th>
                        <th className="c">Qty</th>
                        <th>Items</th>
                      </tr>
                    </thead>
                    <tbody>
                      {pageRows.map((t2, i) => (
                        <tr key={i} className={t2.disc ? "dc" : ""}>
                          <td
                            style={{
                              fontSize: 11,
                              color: "#1f2937",
                              whiteSpace: "nowrap",
                            }}
                          >
                            {t2.date}
                          </td>
                          <td style={{ fontSize: 11, color: "#1f2937" }}>
                            {t2.time}
                          </td>
                          <td
                            className="tm"
                            style={{
                              color: t2.site === "Mercato" ? MERC : MIRD,
                            }}
                          >
                            {MACHINE_LABELS[t2.machine] ||
                              shortMachine(t2.machine)}
                          </td>
                          <td>
                            <span
                              className={`sp ${t2.site === "Mercato" ? "spm" : "spd"}`}
                            >
                              {t2.site}
                            </span>
                          </td>
                          <td className="tp">
                            {t2.psp}
                            {t2.disc && (
                              <span className="db" style={{ marginLeft: 4 }}>
                                {"\u26A0"}
                              </span>
                            )}
                          </td>
                          <td className="c">
                            {t2.funding !== "\u2014" ? (
                              <span
                                className={`tf ${t2.funding === "DEBIT" ? "fd" : t2.funding === "CREDIT" ? "fc" : "fp"}`}
                              >
                                {t2.funding}
                              </span>
                            ) : (
                              <span style={{ color: "#9a948e" }}>
                                {"\u2014"}
                              </span>
                            )}
                          </td>
                          <td
                            className="c"
                            style={{
                              fontSize: 10,
                              color:
                                t2.card === "\u2014" ? "#9a948e" : "#1f2937",
                            }}
                          >
                            {t2.card}
                          </td>
                          <td
                            className="c"
                            style={{
                              fontSize: 10,
                              color:
                                t2.wallet === "\u2014" ? "#9a948e" : "#1f2937",
                            }}
                          >
                            {t2.wallet}
                          </td>
                          <td className="r">
                            <span
                              style={
                                t2.disc
                                  ? {
                                      color: "#EF4444",
                                      fontWeight: 700,
                                      fontSize: 12,
                                    }
                                  : {
                                      color: "#0a0a0a",
                                      fontWeight: 500,
                                      fontSize: 12,
                                    }
                              }
                              title={
                                t2.cash_recovered > 0
                                  ? `Total billed: AED ${t2.total}\nAdyen captured: AED ${t2.adyen_captured}\nCash recovered: AED ${t2.cash_recovered}\nGap: AED ${t2.gap}`
                                  : `Total billed: AED ${t2.total}`
                              }
                            >
                              AED {t2.total}
                            </span>
                          </td>
                          <td className="r">
                            <span
                              style={
                                t2.disc
                                  ? { color: "#F59E0B", fontWeight: 600 }
                                  : t2.cash_recovered > 0
                                    ? { color: "#065F46", fontWeight: 600 }
                                    : ha && t2.captured > 0
                                      ? { color: "#1f2937", fontWeight: 500 }
                                      : { color: "#9a948e" }
                              }
                              title={
                                t2.cash_recovered > 0
                                  ? `Adyen: AED ${t2.adyen_captured} + Cash: AED ${t2.cash_recovered} = AED ${t2.captured}`
                                  : ha && t2.captured > 0
                                    ? `Adyen captured AED ${t2.captured}`
                                    : "No capture record"
                              }
                            >
                              {ha && t2.captured > 0
                                ? `AED ${t2.captured}`
                                : "\u2014"}
                            </span>
                            {t2.disc && t2.merchant_ref && (
                              <button
                                type="button"
                                onClick={(e) => {
                                  e.stopPropagation();
                                  openCashModal({
                                    psp: t2.psp,
                                    merchant_ref: t2.merchant_ref!,
                                    machine: t2.machine,
                                    date: t2.date,
                                    time: t2.time,
                                    total: t2.total,
                                    adyen_captured: t2.adyen_captured,
                                    cash_recovered: t2.cash_recovered,
                                    gap: t2.gap,
                                  });
                                }}
                                title="Log cash recovery for this transaction"
                                style={{
                                  marginLeft: 6,
                                  padding: "1px 6px",
                                  fontSize: 10,
                                  fontWeight: 600,
                                  border: "1px solid #F59E0B",
                                  borderRadius: 4,
                                  background: "white",
                                  color: "#92400E",
                                  cursor: "pointer",
                                  lineHeight: 1.3,
                                }}
                              >
                                + cash
                              </button>
                            )}
                          </td>
                          <td className="c" style={{ color: "#1f2937" }}>
                            {t2.units}
                          </td>
                          <td
                            style={{
                              fontSize: 11,
                              color: "#1f2937",
                              maxWidth: 220,
                            }}
                          >
                            {t2.items}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                {totalPages > 1 && (
                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      justifyContent: "center",
                      gap: 12,
                      padding: "12px 0",
                      fontSize: 12,
                      color: "#9a948e",
                    }}
                  >
                    <button
                      onClick={() => setTxnPage((p) => Math.max(0, p - 1))}
                      disabled={txnPage === 0}
                      style={{
                        background: txnPage === 0 ? "#e8e4de" : "#f5f2ee",
                        color: txnPage === 0 ? "#6b6860" : "#0a0a0a",
                        border: "1px solid #e8e4de",
                        borderRadius: 6,
                        padding: "6px 14px",
                        cursor: txnPage === 0 ? "not-allowed" : "pointer",
                        fontSize: 12,
                      }}
                    >
                      &larr; Prev
                    </button>
                    <span>
                      Page {txnPage + 1} of {totalPages}
                    </span>
                    <button
                      onClick={() =>
                        setTxnPage((p) => Math.min(totalPages - 1, p + 1))
                      }
                      disabled={txnPage >= totalPages - 1}
                      style={{
                        background:
                          txnPage >= totalPages - 1 ? "#e8e4de" : "#f5f2ee",
                        color:
                          txnPage >= totalPages - 1 ? "#6b6860" : "#0a0a0a",
                        border: "1px solid #e8e4de",
                        borderRadius: 6,
                        padding: "6px 14px",
                        cursor:
                          txnPage >= totalPages - 1 ? "not-allowed" : "pointer",
                        fontSize: 12,
                      }}
                    >
                      Next &rarr;
                    </button>
                  </div>
                )}
              </div>
            )}
            {tab === "commercial" && (
              <div className="pg">
                <div style={{ marginBottom: 16 }}>
                  <div className="sl">Financial Reconciliation</div>
                  <h2>MAFE Commercial Reconciliation</h2>
                </div>
                {cLoading && (
                  <div
                    className="cd"
                    style={{
                      padding: 24,
                      textAlign: "center",
                      color: "var(--grey)",
                    }}
                  >
                    Loading commercial report&hellip;
                  </div>
                )}
                {cErr && (
                  <div
                    className="cd"
                    style={{
                      padding: 16,
                      background: "rgba(239,68,68,0.08)",
                      borderColor: "rgba(239,68,68,0.3)",
                      color: "var(--red)",
                    }}
                  >
                    Error: {cErr}
                  </div>
                )}
                {C &&
                  !cLoading &&
                  !cErr &&
                  (() => {
                    const w = C.waterfall;
                    const aed2 = (v: number) =>
                      `AED ${Number(v || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
                    const fmtDate = (s: string) => {
                      try {
                        return new Date(s).toLocaleDateString("en-GB", {
                          day: "2-digit",
                          month: "short",
                        });
                      } catch {
                        return s;
                      }
                    };
                    const discTotal = (C.discrepancies || []).reduce(
                      (a, d) => a + Number(d.gap || 0),
                      0,
                    );
                    const kpis = [
                      {
                        l: "Total Amount",
                        v: aed(w.total_amount),
                        s: `${w.txn_count} txns \u00B7 ${w.units_sold} units`,
                      },
                      {
                        l: "Captured",
                        v: aed(w.captured_amount),
                        s: `${w.default_rate_pct.toFixed(2)}% default`,
                      },
                      {
                        l: "Net Revenue",
                        v: aed(w.net_revenue),
                        s: `after ${w.adyen_fee_pct.toFixed(2)}% Adyen fees`,
                      },
                      {
                        l: "Boonz 20% Share",
                        v: aed(w.boonz_share),
                        s: "of net revenue",
                      },
                      {
                        l: "Boonz COGS",
                        v: aed(w.boonz_cogs),
                        s: `${w.cogs_ratio_pct.toFixed(2)}% of captured`,
                      },
                      {
                        l: "VOX Net Dues",
                        v: aed(w.vox_net_dues),
                        s: "VOX 80% - Boonz COGS",
                      },
                    ];
                    const boonzReceipts =
                      Number(w.boonz_share || 0) + Number(w.boonz_cogs || 0);
                    const legendItems = [
                      { c: "#2A3547", l: "Total Amount", v: w.total_amount },
                      { c: "#EF4444", l: "Default", v: w.default_amount },
                      { c: "#0F4D3A", l: "Captured", v: w.captured_amount },
                      { c: "#EC4899", l: "Refund", v: w.refund_amount },
                      { c: "#F97316", l: "Adyen Fees", v: w.adyen_fees },
                      { c: "#0E3F4D", l: "Net Revenue", v: w.net_revenue },
                      { c: "#F59E0B", l: "Boonz 20%", v: w.boonz_share },
                      { c: "#3D2F63", l: "VOX 80%", v: w.vox_share },
                      { c: "#EF4444", l: "Boonz COGS", v: w.boonz_cogs },
                      { c: "#8B5CF6", l: "VOX Net Dues", v: w.vox_net_dues },
                    ];
                    return (
                      <>
                        <div
                          className="cd"
                          style={{
                            marginBottom: 16,
                            background: "rgba(6,182,212,0.06)",
                            borderColor: "rgba(6,182,212,0.3)",
                            padding: "12px 16px",
                            fontSize: 12,
                            color: "#67E8F9",
                          }}
                        >
                          <strong style={{ color: "#A5F3FC" }}>
                            {w.matched_txns}
                          </strong>{" "}
                          matched {"\u00B7"}{" "}
                          <strong style={{ color: "#A5F3FC" }}>
                            {w.unmatched_txns}
                          </strong>{" "}
                          unmatched {"\u00B7"}{" "}
                          <strong style={{ color: "#A5F3FC" }}>
                            {w.disc_count}
                          </strong>{" "}
                          discrepancies totaling{" "}
                          <strong style={{ color: "#A5F3FC" }}>
                            {aed(discTotal)}
                          </strong>
                        </div>
                        <div
                          style={{
                            display: "grid",
                            gridTemplateColumns:
                              "repeat(auto-fit, minmax(180px, 1fr))",
                            gap: 12,
                            marginBottom: 16,
                          }}
                        >
                          {kpis.map((k, i) => (
                            <div key={i} className="cd" style={{ padding: 14 }}>
                              <div
                                style={{
                                  fontSize: 10,
                                  color: "var(--grey)",
                                  textTransform: "uppercase",
                                  letterSpacing: 1,
                                  marginBottom: 6,
                                }}
                              >
                                {k.l}
                              </div>
                              <div
                                style={{
                                  fontSize: 20,
                                  fontWeight: 700,
                                  color: "#0a0a0a",
                                  marginBottom: 4,
                                }}
                              >
                                {k.v}
                              </div>
                              <div style={{ fontSize: 10, color: "#6b6860" }}>
                                {k.s}
                              </div>
                            </div>
                          ))}
                        </div>
                        <div
                          className="cd"
                          style={{ padding: 16, marginBottom: 16 }}
                        >
                          <div
                            style={{
                              fontSize: 11,
                              color: "var(--grey)",
                              textTransform: "uppercase",
                              letterSpacing: 1,
                              marginBottom: 10,
                            }}
                          >
                            Waterfall
                          </div>
                          <div style={{ position: "relative", height: 460 }}>
                            <canvas ref={wfR} />
                          </div>
                        </div>
                        <div
                          className="cd"
                          style={{ padding: 14, marginBottom: 16 }}
                        >
                          <div
                            style={{
                              display: "grid",
                              gridTemplateColumns:
                                "repeat(auto-fit, minmax(180px, 1fr))",
                              gap: 10,
                            }}
                          >
                            {legendItems.map((it, i) => (
                              <div
                                key={i}
                                style={{
                                  display: "flex",
                                  alignItems: "center",
                                  gap: 8,
                                  fontSize: 11,
                                }}
                              >
                                <span
                                  style={{
                                    width: 12,
                                    height: 12,
                                    background: it.c,
                                    borderRadius: 2,
                                    flexShrink: 0,
                                  }}
                                />
                                <span style={{ color: "#9a948e", flex: 1 }}>
                                  {it.l}
                                </span>
                                <span
                                  style={{ color: "#0a0a0a", fontWeight: 600 }}
                                >
                                  {aed(it.v)}
                                </span>
                              </div>
                            ))}
                          </div>
                        </div>
                        <div
                          style={{
                            display: "grid",
                            gridTemplateColumns: "1fr 1fr",
                            gap: 16,
                            marginBottom: 16,
                          }}
                        >
                          <div className="cd" style={{ padding: 16 }}>
                            <div
                              style={{
                                fontSize: 11,
                                color: "var(--grey)",
                                textTransform: "uppercase",
                                letterSpacing: 1,
                                marginBottom: 12,
                              }}
                            >
                              Waterfall By Site
                            </div>
                            <div
                              style={{
                                display: "flex",
                                flexDirection: "column",
                                gap: 12,
                              }}
                            >
                              {C.by_site.map((s, i) => {
                                const isMerc = s.site === "Mercato";
                                return (
                                  <div
                                    key={i}
                                    style={{
                                      borderLeft: `3px solid ${isMerc ? MERC : MIRD}`,
                                      paddingLeft: 12,
                                    }}
                                  >
                                    <div
                                      style={{
                                        display: "flex",
                                        justifyContent: "space-between",
                                        marginBottom: 6,
                                      }}
                                    >
                                      <span
                                        style={{
                                          color: isMerc ? MERC : MIRD,
                                          fontWeight: 600,
                                          fontSize: 13,
                                        }}
                                      >
                                        {s.site}
                                      </span>
                                      <span
                                        style={{
                                          color: "#9a948e",
                                          fontSize: 11,
                                        }}
                                      >
                                        {s.txns} txns {"\u00B7"} {s.units} units
                                      </span>
                                    </div>
                                    <div
                                      style={{
                                        display: "grid",
                                        gridTemplateColumns: "1fr 1fr",
                                        gap: 6,
                                        fontSize: 11,
                                      }}
                                    >
                                      <div style={{ color: "#6b6860" }}>
                                        Total
                                      </div>
                                      <div
                                        style={{
                                          color: "#0a0a0a",
                                          textAlign: "right",
                                        }}
                                      >
                                        {aed(s.total_amount)}
                                      </div>
                                      <div style={{ color: "#6b6860" }}>
                                        Captured
                                      </div>
                                      <div
                                        style={{
                                          color: "#0a0a0a",
                                          textAlign: "right",
                                        }}
                                      >
                                        {aed(s.captured_amount)}
                                      </div>
                                      <div style={{ color: "#6b6860" }}>
                                        Net Revenue
                                      </div>
                                      <div
                                        style={{
                                          color: "#0a0a0a",
                                          textAlign: "right",
                                        }}
                                      >
                                        {aed(s.net_revenue)}
                                      </div>
                                      <div style={{ color: "#6b6860" }}>
                                        Boonz 20%
                                      </div>
                                      <div
                                        style={{
                                          color: "#F59E0B",
                                          textAlign: "right",
                                        }}
                                      >
                                        {aed(s.boonz_share)}
                                      </div>
                                      <div style={{ color: "#6b6860" }}>
                                        Boonz COGS
                                      </div>
                                      <div
                                        style={{
                                          color: "#EF4444",
                                          textAlign: "right",
                                        }}
                                      >
                                        {aed(s.boonz_cogs)}
                                      </div>
                                      <div style={{ color: "#6b6860" }}>
                                        VOX Net Dues
                                      </div>
                                      <div
                                        style={{
                                          color: "#8B5CF6",
                                          textAlign: "right",
                                          fontWeight: 600,
                                        }}
                                      >
                                        {aed(s.vox_net_dues)}
                                      </div>
                                    </div>
                                  </div>
                                );
                              })}
                            </div>
                          </div>
                          <div className="cd" style={{ padding: 16 }}>
                            <div
                              style={{
                                fontSize: 11,
                                color: "var(--grey)",
                                textTransform: "uppercase",
                                letterSpacing: 1,
                                marginBottom: 12,
                              }}
                            >
                              Boonz Receipts Breakdown
                            </div>
                            <div
                              style={{
                                position: "relative",
                                height: 220,
                                marginBottom: 12,
                              }}
                            >
                              <canvas ref={brR} />
                            </div>
                            <div
                              style={{
                                display: "grid",
                                gridTemplateColumns: "1fr auto",
                                gap: 6,
                                fontSize: 11,
                                borderTop: "1px solid var(--border)",
                                paddingTop: 10,
                              }}
                            >
                              <div style={{ color: "#6b6860" }}>
                                Boonz 20% Share
                              </div>
                              <div
                                style={{ color: "#F59E0B", fontWeight: 600 }}
                              >
                                {aed(w.boonz_share)}
                              </div>
                              <div style={{ color: "#6b6860" }}>Boonz COGS</div>
                              <div
                                style={{ color: "#EF4444", fontWeight: 600 }}
                              >
                                {aed(w.boonz_cogs)}
                              </div>
                              <div
                                style={{
                                  color: "#0a0a0a",
                                  fontWeight: 600,
                                  borderTop: "1px solid var(--border)",
                                  paddingTop: 6,
                                }}
                              >
                                Total Receipts
                              </div>
                              <div
                                style={{
                                  color: "#0a0a0a",
                                  fontWeight: 700,
                                  borderTop: "1px solid var(--border)",
                                  paddingTop: 6,
                                }}
                              >
                                {aed(boonzReceipts)}
                              </div>
                            </div>
                          </div>
                        </div>
                        <div
                          className="cd"
                          style={{ padding: 0, overflow: "hidden" }}
                        >
                          {(() => {
                            const cqLower = cq.trim().toLowerCase();
                            const fmtDateLocal = (s: string) => {
                              try {
                                return new Date(s).toLocaleString("en-GB", {
                                  day: "2-digit",
                                  month: "short",
                                  hour: "2-digit",
                                  minute: "2-digit",
                                });
                              } catch {
                                return s;
                              }
                            };
                            const filteredTxns = cqLower
                              ? C.transactions.filter((t) => {
                                  const haystack = [
                                    fmtDateLocal(t.txn_date),
                                    t.site,
                                    t.machine,
                                    t.items,
                                    (t as any).psp || t.psp_reference || "",
                                    String(t.units),
                                    String(t.total_amount),
                                    String(t.captured_amount),
                                    String(t.default_amount),
                                    String(t.refunded_amount),
                                    String(t.adyen_fees),
                                    String(t.net_revenue),
                                    String(t.boonz_share),
                                    String(t.vox_share),
                                    String(t.boonz_cogs),
                                    t.matched ? "ok" : "no adyen",
                                    Number(t.default_amount || 0) > 0
                                      ? "default"
                                      : "",
                                  ]
                                    .join(" § ")
                                    .toLowerCase();
                                  return haystack.includes(cqLower);
                                })
                              : C.transactions;
                            // AC4: SKU line-level export via get_vox_commercial_txn_lines (UTF-8 BOM).
                            const downloadLineCsv = async () => {
                              try {
                                const qs = new URLSearchParams({
                                  pods: pods.join(","),
                                  date_from: dateFrom,
                                  date_to: dateTo,
                                });
                                const res = await fetch(
                                  `/api/vox/commercial-lines?${qs.toString()}`,
                                );
                                if (!res.ok)
                                  throw new Error(`HTTP ${res.status}`);
                                const lines: any[] = await res.json();
                                const h = [
                                  "Base Txn",
                                  "PSP",
                                  "Date",
                                  "Site",
                                  "Machine",
                                  "Product",
                                  "Qty",
                                  "Unit Price",
                                  "Line Total",
                                  "Unit COGS",
                                  "Line COGS",
                                  "Supply Source",
                                  "Txn Captured",
                                  "Txn Default",
                                  "Txn Refunded",
                                  "Txn Status",
                                ];
                                const esc = (v: any) => {
                                  const s =
                                    v === null || v === undefined
                                      ? ""
                                      : String(v);
                                  return /[",\n]/.test(s)
                                    ? `"${s.replace(/"/g, '""')}"`
                                    : s;
                                };
                                const rows = lines.map((l) =>
                                  [
                                    l.base_txn_sn,
                                    l.psp_reference || "",
                                    fmtDateLocal(l.transaction_date),
                                    l.site,
                                    l.machine,
                                    l.pod_product_name,
                                    l.qty,
                                    l.unit_price,
                                    l.line_total,
                                    l.unit_cogs ?? "",
                                    l.line_cogs,
                                    l.supply_source,
                                    l.txn_captured,
                                    l.txn_default,
                                    l.txn_refunded,
                                    l.txn_status,
                                  ]
                                    .map(esc)
                                    .join(","),
                                );
                                // UTF-8 BOM so Excel reads it as UTF-8.
                                const csv =
                                  "﻿" + [h.join(","), ...rows].join("\n");
                                const blob = new Blob([csv], {
                                  type: "text/csv;charset=utf-8;",
                                });
                                const url = URL.createObjectURL(blob);
                                const a = document.createElement("a");
                                a.href = url;
                                a.download = `VOX_Commercial_Lines_${dateFrom}_${dateTo}.csv`;
                                document.body.appendChild(a);
                                a.click();
                                document.body.removeChild(a);
                                URL.revokeObjectURL(url);
                              } catch (e: any) {
                                alert(
                                  `Line detail export failed: ${e?.message ?? String(e)}`,
                                );
                              }
                            };
                            const downloadCsv = () => {
                              const headers = [
                                "Date",
                                "Site",
                                "Machine",
                                "Items",
                                "Qty",
                                "Total",
                                "Captured",
                                "Default",
                                "Refund",
                                "Adyen Fees",
                                "Net Revenue",
                                "Boonz 20%",
                                "VOX 80%",
                                "Boonz COGS",
                                "PSP",
                                "Status",
                              ];
                              const escape = (v: any) => {
                                const s =
                                  v === null || v === undefined
                                    ? ""
                                    : String(v);
                                return /[",\n]/.test(s)
                                  ? `"${s.replace(/"/g, '""')}"`
                                  : s;
                              };
                              const rows = filteredTxns.map((t) =>
                                [
                                  fmtDateLocal(t.txn_date),
                                  t.site,
                                  t.machine,
                                  t.items,
                                  t.units,
                                  t.total_amount,
                                  t.captured_amount,
                                  t.default_amount,
                                  t.refunded_amount,
                                  t.adyen_fees,
                                  t.net_revenue,
                                  t.boonz_share,
                                  t.vox_share,
                                  t.boonz_cogs,
                                  t.psp_reference || "",
                                  Number(t.default_amount || 0) > 0
                                    ? "DEFAULT"
                                    : t.matched
                                      ? "OK"
                                      : "NO ADYEN",
                                ]
                                  .map(escape)
                                  .join(","),
                              );
                              const csv = [headers.join(","), ...rows].join(
                                "\n",
                              );
                              const blob = new Blob([csv], {
                                type: "text/csv;charset=utf-8;",
                              });
                              const url = URL.createObjectURL(blob);
                              const a = document.createElement("a");
                              a.href = url;
                              a.download = `mafe-transactions-${dateFrom}-to-${dateTo}.csv`;
                              document.body.appendChild(a);
                              a.click();
                              document.body.removeChild(a);
                              URL.revokeObjectURL(url);
                            };
                            return (
                              <>
                                <div
                                  style={{
                                    padding: "12px 16px",
                                    borderBottom: "1px solid var(--border)",
                                    display: "flex",
                                    alignItems: "center",
                                    gap: 12,
                                    background: "var(--surface2)",
                                    flexWrap: "wrap",
                                  }}
                                >
                                  <span
                                    style={{
                                      fontFamily: "var(--font-head)",
                                      fontSize: 14,
                                      fontWeight: 700,
                                      color: "var(--white)",
                                      letterSpacing: "-0.2px",
                                    }}
                                  >
                                    Transaction Detail
                                  </span>
                                  <span
                                    style={{
                                      fontFamily: "var(--font-mono)",
                                      fontSize: 11,
                                      fontWeight: 500,
                                      color: "var(--grey)",
                                    }}
                                  >
                                    {cqLower
                                      ? `${filteredTxns.length.toLocaleString()} of ${C.transactions.length.toLocaleString()} rows`
                                      : `${C.transactions.length.toLocaleString()} rows`}
                                  </span>
                                  <div style={{ flex: 1 }} />
                                  <input
                                    type="text"
                                    placeholder="Search machine, item, PSP, amount…"
                                    value={cq}
                                    onChange={(e) => setCq(e.target.value)}
                                    style={{
                                      padding: "6px 12px",
                                      borderRadius: 4,
                                      border: "1px solid var(--border)",
                                      background: "var(--surface)",
                                      color: "var(--white)",
                                      fontSize: 11,
                                      fontFamily: "var(--font-mono)",
                                      outline: "none",
                                      width: 260,
                                    }}
                                  />
                                  {cq && (
                                    <button
                                      onClick={() => setCq("")}
                                      className="cbb"
                                      title="Clear search"
                                      style={{ padding: "5px 10px" }}
                                    >
                                      ×
                                    </button>
                                  )}
                                  <button
                                    onClick={downloadCsv}
                                    className="cbb"
                                    title="Download transactions (current view) as CSV"
                                    style={{
                                      borderColor: MERC,
                                      color: MERC,
                                      background: `${MERC}10`,
                                      fontWeight: 600,
                                    }}
                                  >
                                    ↓ Transactions
                                  </button>
                                  <button
                                    onClick={downloadLineCsv}
                                    className="cbb"
                                    title="Download SKU line detail (one row per item, includes VOX-sourced lines)"
                                    style={{
                                      borderColor: MERC,
                                      color: MERC,
                                      background: `${MERC}10`,
                                      fontWeight: 600,
                                    }}
                                  >
                                    ↓ Line detail (SKU)
                                  </button>
                                </div>
                                <div
                                  className="tw"
                                  style={{ maxHeight: 640, overflow: "auto" }}
                                >
                                  <table>
                                    <thead
                                      style={{
                                        position: "sticky",
                                        top: 0,
                                        background: "var(--surface)",
                                        zIndex: 1,
                                      }}
                                    >
                                      <tr>
                                        <th>Date</th>
                                        <th>Site</th>
                                        <th>Machine</th>
                                        <th>Items</th>
                                        <th className="c">Qty</th>
                                        <th className="r">Total</th>
                                        <th className="r">Captured</th>
                                        <th className="r">Default</th>
                                        <th className="r">Refund</th>
                                        <th className="r">Adyen Fees</th>
                                        <th className="r">Net Rev</th>
                                        <th className="r">Boonz 20%</th>
                                        <th className="r">VOX 80%</th>
                                        <th className="r">Boonz COGS</th>
                                        <th className="c">Status</th>
                                      </tr>
                                    </thead>
                                    <tbody>
                                      {filteredTxns.map((t, i) => {
                                        const isDisc =
                                          Number(t.default_amount || 0) > 0;
                                        const isUnmatched = !t.matched;
                                        const rowStyle: React.CSSProperties = {
                                          ...(isDisc
                                            ? {
                                                background:
                                                  "rgba(239,68,68,0.06)",
                                              }
                                            : {}),
                                          ...(isUnmatched
                                            ? { opacity: 0.6 }
                                            : {}),
                                        };
                                        const isMerc = t.site === "Mercato";
                                        const status = isDisc
                                          ? "DEFAULT"
                                          : isUnmatched
                                            ? "NO ADYEN"
                                            : "OK";
                                        const statusColor = isDisc
                                          ? "#EF4444"
                                          : isUnmatched
                                            ? "#9a948e"
                                            : "#10B981";
                                        return (
                                          <tr key={i} style={rowStyle}>
                                            <td
                                              style={{
                                                fontSize: 11,
                                                color: "#9a948e",
                                                whiteSpace: "nowrap",
                                              }}
                                            >
                                              {fmtDate(t.txn_date)}
                                            </td>
                                            <td>
                                              <span
                                                className={`sp ${isMerc ? "spm" : "spd"}`}
                                              >
                                                {t.site}
                                              </span>
                                            </td>
                                            <td
                                              className="tm"
                                              style={{
                                                color: isMerc ? MERC : MIRD,
                                              }}
                                            >
                                              {MACHINE_LABELS[t.machine] ||
                                                shortMachine(t.machine)}
                                            </td>
                                            <td
                                              style={{
                                                fontSize: 11,
                                                color: "#9a948e",
                                                maxWidth: 220,
                                              }}
                                            >
                                              {t.items}
                                            </td>
                                            <td
                                              className="c"
                                              style={{ color: "#9a948e" }}
                                            >
                                              {t.units}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color: "#0a0a0a",
                                                fontSize: 11,
                                              }}
                                            >
                                              {aed2(t.total_amount)}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color:
                                                  (t.cash_recovered ?? 0) > 0
                                                    ? "#065F46"
                                                    : "#9a948e",
                                                fontSize: 11,
                                                fontWeight:
                                                  (t.cash_recovered ?? 0) > 0
                                                    ? 600
                                                    : 400,
                                              }}
                                              title={
                                                (t.cash_recovered ?? 0) > 0
                                                  ? `Adyen: AED ${(t.adyen_captured ?? 0).toFixed(2)} + Cash: AED ${(t.cash_recovered ?? 0).toFixed(2)} = AED ${t.captured_amount.toFixed(2)}`
                                                  : `Adyen captured AED ${t.captured_amount.toFixed(2)}`
                                              }
                                            >
                                              {aed2(t.captured_amount)}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color: isDisc
                                                  ? "#EF4444"
                                                  : "#9a948e",
                                                fontSize: 11,
                                                fontWeight: isDisc ? 700 : 400,
                                              }}
                                            >
                                              {isDisc
                                                ? aed2(t.default_amount)
                                                : "\u2014"}
                                              {isDisc &&
                                                (t.merchant_ref ||
                                                  t.txn_base) && (
                                                  <button
                                                    type="button"
                                                    onClick={(e) => {
                                                      e.stopPropagation();
                                                      openCashModal({
                                                        psp: (
                                                          t.psp_reference ||
                                                          "\u2014"
                                                        ).slice(0, 16),
                                                        merchant_ref:
                                                          (t.merchant_ref ||
                                                            t.txn_base)!,
                                                        machine: t.machine,
                                                        date: fmtDate(
                                                          t.txn_date,
                                                        ),
                                                        time: "",
                                                        total:
                                                          Number(
                                                            t.total_amount,
                                                          ) || 0,
                                                        adyen_captured:
                                                          Number(
                                                            t.adyen_captured ??
                                                              t.captured_amount,
                                                          ) || 0,
                                                        cash_recovered:
                                                          Number(
                                                            t.cash_recovered ??
                                                              0,
                                                          ) || 0,
                                                        gap:
                                                          Number(
                                                            t.default_amount,
                                                          ) || 0,
                                                      });
                                                    }}
                                                    title="Log cash recovery for this transaction"
                                                    style={{
                                                      marginLeft: 6,
                                                      padding: "1px 6px",
                                                      fontSize: 9,
                                                      fontWeight: 600,
                                                      border:
                                                        "1px solid #F59E0B",
                                                      borderRadius: 4,
                                                      background: "white",
                                                      color: "#92400E",
                                                      cursor: "pointer",
                                                      lineHeight: 1.3,
                                                    }}
                                                  >
                                                    + cash
                                                  </button>
                                                )}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color:
                                                  Number(t.refunded_amount) > 0
                                                    ? "#EC4899"
                                                    : "#9a948e",
                                                fontSize: 11,
                                              }}
                                            >
                                              {Number(t.refunded_amount) > 0
                                                ? aed2(t.refunded_amount)
                                                : "\u2014"}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color: "#F97316",
                                                fontSize: 11,
                                              }}
                                            >
                                              {aed2(t.adyen_fees)}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color: "#9a948e",
                                                fontSize: 11,
                                              }}
                                            >
                                              {aed2(t.net_revenue)}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color: "#F59E0B",
                                                fontSize: 11,
                                              }}
                                            >
                                              {aed2(t.boonz_share)}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color: "#9a948e",
                                                fontSize: 11,
                                              }}
                                            >
                                              {aed2(t.vox_share)}
                                            </td>
                                            <td
                                              className="r"
                                              style={{
                                                color: "#EF4444",
                                                fontSize: 11,
                                              }}
                                            >
                                              {aed2(t.boonz_cogs)}
                                            </td>
                                            <td className="c">
                                              <span
                                                style={{
                                                  fontSize: 9,
                                                  color: statusColor,
                                                  fontWeight: 700,
                                                  letterSpacing: 0.5,
                                                }}
                                              >
                                                {status}
                                              </span>
                                            </td>
                                          </tr>
                                        );
                                      })}
                                    </tbody>
                                  </table>
                                </div>
                              </>
                            );
                          })()}
                        </div>
                      </>
                    );
                  })()}
              </div>
            )}
          </>
        )}
        <footer>
          MAFE {"\u00B7"} Consumer Report {"\u00B7"} Boonz Smart Vending{" "}
          {"\u00B7"} Supabase (Weimi + Adyen)
        </footer>
      </div>

      {/* \u2500\u2500 Cash Recovery modal \u2500\u2500 */}
      {crOpen && crTxn && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            zIndex: 300,
            background: "rgba(0,0,0,0.45)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontFamily: "'Plus Jakarta Sans', sans-serif",
          }}
          onClick={() => !crSubmitting && setCrOpen(false)}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            style={{
              background: "white",
              borderRadius: 12,
              padding: 24,
              width: 480,
              maxWidth: "92vw",
              boxShadow: "0 20px 50px rgba(0,0,0,0.25)",
            }}
          >
            <h3
              style={{
                margin: 0,
                marginBottom: 4,
                fontSize: 18,
                fontWeight: 800,
                color: "#0a0a0a",
                letterSpacing: "-0.01em",
              }}
            >
              Log cash recovery
            </h3>
            <p
              style={{
                marginTop: 0,
                marginBottom: 14,
                fontSize: 12,
                color: "#6b6860",
              }}
            >
              {crTxn.date} {crTxn.time} {"\u00B7"} {crTxn.machine} {"\u00B7"}{" "}
              psp {crTxn.psp}
            </p>

            <div
              style={{
                display: "grid",
                gridTemplateColumns: "1fr 1fr",
                gap: 8,
                padding: 10,
                borderRadius: 8,
                background: "#FAF9F7",
                marginBottom: 16,
                fontSize: 12,
              }}
            >
              <div>
                <strong>Total billed:</strong> AED {crTxn.total.toFixed(2)}
              </div>
              <div>
                <strong>Adyen captured:</strong> AED{" "}
                {crTxn.adyen_captured.toFixed(2)}
              </div>
              <div>
                <strong>Cash already logged:</strong> AED{" "}
                {crTxn.cash_recovered.toFixed(2)}
              </div>
              <div style={{ color: crTxn.gap > 0 ? "#991B1B" : "#065F46" }}>
                <strong>Remaining gap:</strong> AED {crTxn.gap.toFixed(2)}
              </div>
            </div>

            <label style={{ display: "block", marginBottom: 12 }}>
              <span
                style={{
                  display: "block",
                  fontSize: 10,
                  fontWeight: 500,
                  letterSpacing: "0.08em",
                  textTransform: "uppercase",
                  color: "#6b6860",
                  marginBottom: 3,
                }}
              >
                Amount (AED)
              </span>
              <input
                type="number"
                step="0.01"
                min="0.01"
                value={crAmount}
                onChange={(e) => setCrAmount(e.target.value)}
                style={{
                  width: "100%",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "8px 10px",
                  fontSize: 14,
                  color: "#0a0a0a",
                  outline: "none",
                }}
                autoFocus
              />
            </label>

            <label style={{ display: "block", marginBottom: 12 }}>
              <span
                style={{
                  display: "block",
                  fontSize: 10,
                  fontWeight: 500,
                  letterSpacing: "0.08em",
                  textTransform: "uppercase",
                  color: "#6b6860",
                  marginBottom: 3,
                }}
              >
                Tender method
              </span>
              <select
                value={crTender}
                onChange={(e) => setCrTender(e.target.value as CashTender)}
                style={{
                  width: "100%",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "8px 10px",
                  fontSize: 14,
                  color: "#0a0a0a",
                  background: "white",
                  outline: "none",
                  cursor: "pointer",
                }}
              >
                <option value="cash">Cash</option>
                <option value="card_retry">Card retry</option>
                <option value="bank_transfer">Bank transfer</option>
                <option value="voucher">Voucher</option>
                <option value="other">Other</option>
              </select>
            </label>

            <label style={{ display: "block", marginBottom: 12 }}>
              <span
                style={{
                  display: "block",
                  fontSize: 10,
                  fontWeight: 500,
                  letterSpacing: "0.08em",
                  textTransform: "uppercase",
                  color: "#6b6860",
                  marginBottom: 3,
                }}
              >
                Collected by (optional)
              </span>
              <input
                type="text"
                value={crCollector}
                onChange={(e) => setCrCollector(e.target.value)}
                placeholder="e.g. driver name"
                style={{
                  width: "100%",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "8px 10px",
                  fontSize: 14,
                  color: "#0a0a0a",
                  outline: "none",
                }}
              />
            </label>

            <label style={{ display: "block", marginBottom: 18 }}>
              <span
                style={{
                  display: "block",
                  fontSize: 10,
                  fontWeight: 500,
                  letterSpacing: "0.08em",
                  textTransform: "uppercase",
                  color: "#6b6860",
                  marginBottom: 3,
                }}
              >
                Reason (required, min 5 chars)
              </span>
              <textarea
                value={crReason}
                onChange={(e) => setCrReason(e.target.value)}
                rows={3}
                style={{
                  width: "100%",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "8px 10px",
                  fontSize: 13,
                  color: "#0a0a0a",
                  outline: "none",
                  resize: "vertical",
                  fontFamily: "'Plus Jakarta Sans', sans-serif",
                }}
              />
            </label>

            <div style={{ display: "flex", gap: 8 }}>
              <button
                onClick={() => setCrOpen(false)}
                disabled={crSubmitting}
                style={{
                  flex: 1,
                  padding: "10px 16px",
                  borderRadius: 8,
                  border: "1px solid #e8e4de",
                  background: "white",
                  color: "#6b6860",
                  fontWeight: 600,
                  fontSize: 14,
                  cursor: crSubmitting ? "not-allowed" : "pointer",
                }}
              >
                Cancel
              </button>
              <button
                onClick={submitCashRecovery}
                disabled={crSubmitting}
                style={{
                  flex: 2,
                  padding: "10px 16px",
                  borderRadius: 8,
                  border: "none",
                  background: "#24544a",
                  color: "white",
                  fontWeight: 600,
                  fontSize: 14,
                  cursor: crSubmitting ? "not-allowed" : "pointer",
                  opacity: crSubmitting ? 0.7 : 1,
                }}
              >
                {crSubmitting ? "Logging\u2026" : "Log recovery"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* \u2500\u2500 Cash recovery toast \u2500\u2500 */}
      {crToast && (
        <div
          style={{
            position: "fixed",
            bottom: 24,
            right: 24,
            zIndex: 250,
            padding: "10px 16px",
            borderRadius: 8,
            fontSize: 14,
            fontWeight: 600,
            boxShadow: "0 10px 25px rgba(0,0,0,0.15)",
            background: crToast.ok ? "#ECFDF5" : "#FEF2F2",
            color: crToast.ok ? "#065F46" : "#991B1B",
            border: crToast.ok ? "1px solid #A7F3D0" : "1px solid #FECACA",
            fontFamily: "'Plus Jakarta Sans', sans-serif",
            maxWidth: 400,
          }}
        >
          {crToast.ok ? "\u2713 " : "\u2715 "}
          {crToast.msg}
        </div>
      )}
    </>
  );
}
