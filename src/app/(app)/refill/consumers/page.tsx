"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import Script from "next/script";
import {
  type VoxConsumerReport,
  type VoxCommercialReport,
  VOX_PODS,
  MACHINE_LABELS,
  WALLET_NAMES,
  FUND_COLORS,
  CARD_COLORS,
  PROD_COLORS,
  aed,
  pct,
  fetchVoxConsumerReport,
  fetchVoxCommercialReport,
} from "@/lib/vox-data";

const GRID = "#1E2D42";
const MERC = "#3B82F6";
const MIRD = "#10B981";
const COMBINED = "#8B5CF6";
const PLUG = {
  legend: { display: false },
  tooltip: {
    backgroundColor: "#0F1520",
    borderColor: GRID,
    borderWidth: 1,
    titleColor: "#E8EDF5",
    bodyColor: "#8892A4",
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

const CSS = `@import url('https://fonts.googleapis.com/css2?family=DM+Mono:wght@300;400;500&family=Syne:wght@400;600;700;800&display=swap');
:root{--bg:#080C12;--surface:#0F1520;--surface2:#161F2E;--border:#1E2D42;--merc:#3B82F6;--merc-dim:rgba(59,130,246,0.12);--mird:#10B981;--mird-dim:rgba(16,185,129,0.12);--amber:#F59E0B;--red:#EF4444;--white:#E8EDF5;--grey:#5A6A80;--grey2:#8892A4;--font-head:'Syne',sans-serif;--font-mono:'DM Mono',monospace}
.vr{background:var(--bg);color:var(--white);font-family:var(--font-mono);font-size:13px;line-height:1.5;min-height:100vh}.vr *{box-sizing:border-box}
.vr nav{position:sticky;top:0;z-index:100;background:rgba(8,12,18,0.95);backdrop-filter:blur(12px);border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 24px;flex-wrap:wrap}
.nb{font-family:var(--font-head);font-weight:800;font-size:15px;padding:14px 24px 14px 0;border-right:1px solid var(--border);margin-right:8px;letter-spacing:-0.5px}
.nt{padding:14px 18px;font-size:11px;font-family:var(--font-mono);letter-spacing:0.08em;text-transform:uppercase;color:var(--grey);cursor:pointer;border-bottom:2px solid transparent;transition:all 0.2s;white-space:nowrap}.nt:hover{color:var(--white)}.nt.a{color:var(--white);border-bottom-color:var(--merc)}
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
.si{padding:10px 16px;display:flex;justify-content:space-between;align-items:center}.si.sm{background:var(--merc-dim);border:1px solid rgba(59,130,246,0.2)}.si.sd{background:var(--mird-dim);border:1px solid rgba(16,185,129,0.2);border-left:none}
.si .sn{font-family:var(--font-head);font-weight:700;font-size:13px}.sn.snm{color:var(--merc)}.sn.sni{color:var(--mird)}
.si .st{font-size:11px;color:var(--grey2);display:flex;gap:16px}.si .st strong{color:var(--white)}
.pr{display:flex;align-items:center;gap:10px;margin-bottom:8px}.pl{font-size:11px;color:var(--grey2);width:140px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex-shrink:0}.pb{flex:1;height:6px;background:var(--border);border-radius:2px;overflow:hidden}.pf{height:100%;border-radius:2px;transition:width .8s ease}.pv{font-size:11px;color:var(--white);width:52px;text-align:right;font-weight:500;flex-shrink:0}.pp{font-size:10px;color:var(--grey);width:30px;text-align:right;flex-shrink:0}
.lg{display:flex;gap:16px;align-items:center;flex-wrap:wrap;margin-bottom:12px}.li{display:flex;align-items:center;gap:6px;font-size:11px;color:var(--grey2)}.ld{width:10px;height:10px;border-radius:2px;flex-shrink:0}
.tw{overflow-x:auto;border-radius:6px;border:1px solid var(--border)}.vr table{width:100%;border-collapse:collapse;font-size:11.5px;min-width:900px}.vr thead th{background:var(--surface2);padding:10px 12px;text-align:left;font-size:9.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--grey);font-weight:500;white-space:nowrap;border-bottom:1px solid var(--border)}.vr thead th.r{text-align:right}.vr thead th.c{text-align:center}.vr tbody tr{border-bottom:1px solid var(--border);transition:background .15s}.vr tbody tr:hover{background:var(--surface2)}.vr tbody tr.dc{background:rgba(239,68,68,.06)}.vr tbody td{padding:9px 12px;vertical-align:middle}.vr tbody td.r{text-align:right}.vr tbody td.c{text-align:center}
.tm{font-size:11px;font-weight:500;white-space:nowrap}.tp{font-size:10px;color:rgba(96,165,250,.7);font-family:var(--font-mono)}.tf{font-size:10px;padding:2px 7px;border-radius:3px;display:inline-block;font-weight:500}.fd{background:rgba(59,130,246,.12);color:#60A5FA}.fc{background:rgba(16,185,129,.12);color:#34D399}.fp{background:rgba(245,158,11,.12);color:#FCD34D}
.sp{font-size:9.5px;padding:2px 8px;border-radius:2px;font-weight:600;display:inline-block;letter-spacing:.05em;text-transform:uppercase}.spm{background:var(--merc-dim);color:var(--merc)}.spd{background:var(--mird-dim);color:var(--mird)}
.db{font-size:9px;padding:2px 6px;background:rgba(239,68,68,.15);color:var(--red);border-radius:2px;display:inline-block}
.fb{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:14px}.fn{padding:6px 14px;border-radius:4px;border:1px solid var(--border);background:var(--surface);color:var(--grey2);font-size:11px;font-family:var(--font-mono);cursor:pointer;transition:all .15s}.fn:hover,.fn.a{border-color:var(--merc);color:var(--white);background:var(--merc-dim)}.fn.mb:hover,.fn.mb.a{border-color:var(--mird);color:var(--white);background:var(--mird-dim)}
.fs{flex:1}.cl{font-size:11px;color:var(--grey)}
.vr input[type=text]{padding:6px 12px;border-radius:4px;border:1px solid var(--border);background:var(--surface);color:var(--white);font-size:11px;font-family:var(--font-mono);outline:none;width:220px}.vr input[type=text]:focus{border-color:var(--merc)}.vr input::placeholder{color:var(--grey)}
.vr input[type=date]{padding:5px 10px;border-radius:4px;border:1px solid var(--border);background:var(--surface);color:var(--white);font-size:11px;font-family:var(--font-mono);outline:none}.vr input[type=date]:focus{border-color:var(--merc)}.vr input[type=date]::-webkit-calendar-picker-indicator{filter:invert(0.7)}
.pw{display:flex;align-items:center;gap:10px;padding:8px 12px;background:var(--surface2);border-radius:4px;margin-bottom:4px}.pd{width:8px;height:8px;border-radius:50%;flex-shrink:0}.pn{flex:1;font-size:11px;color:var(--grey2)}.pc{font-size:11px;color:var(--grey);width:30px;text-align:right}.pa{font-size:12px;color:var(--white);font-weight:500;width:75px;text-align:right}.pe{font-size:10px;color:var(--grey);width:35px;text-align:right}
.eb{border:1px solid rgba(245,158,11,.3);background:rgba(245,158,11,.05);border-radius:6px;padding:14px 18px}.eb h4{font-family:var(--font-head);font-size:13px;color:var(--amber);margin-bottom:6px}
.cb{background:#0D1117;border-bottom:1px solid #1E2D42;padding:10px 24px;display:flex;align-items:center;gap:14px;flex-wrap:wrap}
.cbl{font-size:10px;color:#5A6A80;text-transform:uppercase;letter-spacing:.1em}
.cbb{padding:5px 14px;border-radius:4px;font-size:11px;font-family:var(--font-mono);cursor:pointer;border:1px solid var(--border);background:var(--surface);color:var(--grey);transition:all .15s}
.csep{width:1px;height:20px;background:#1E2D42;margin:0 4px}
.rbtn{padding:5px 12px;border-radius:4px;font-size:11px;font-family:var(--font-mono);cursor:pointer;border:1px solid var(--border);background:var(--surface);color:var(--grey2);transition:all .15s;display:flex;align-items:center;gap:6px}.rbtn:hover{border-color:var(--merc);color:var(--white)}
.vr footer{text-align:center;padding:28px 24px;color:var(--grey);font-size:10px;letter-spacing:.05em;border-top:1px solid var(--border);margin-top:40px}`;

export default function VOXConsumersPage() {
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
  const [dateFrom, setDateFrom] = useState("2026-02-06");
  const [dateTo, setDateTo] = useState(new Date().toISOString().split("T")[0]);
  const [lastUpdated, setLastUpdated] = useState<string | null>(null);

  const isC = vm === "consolidated" && pods.length > 1;

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
  const [C, setC] = useState<VoxCommercialReport | null>(null);
  const [cLoading, setCLoading] = useState(false);
  const [cErr, setCErr] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      setD(await fetchVoxConsumerReport(pods, isC, dateFrom, dateTo));
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
  }, [pods, vm, dateFrom, dateTo]);
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
  useEffect(() => {
    if (tab === "commercial") loadCommercial();
  }, [tab, loadCommercial]);

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
                  labels: { color: "#8892A4", boxWidth: 12 },
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
                  labels: { color: "#8892A4", boxWidth: 12 },
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
                borderColor: "#080C12",
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
                  color: "#8892A4",
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
                    color: "#5A6A80",
                    font: { size: 10 },
                  },
                  beginAtZero: true,
                },
                y: {
                  grid: { color: GRID },
                  title: {
                    display: true,
                    text: "\u2191 Avg Price (AED)",
                    color: "#5A6A80",
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
                  borderColor: "#080C12",
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
                    color: "#8892A4",
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
                  borderColor: "#080C12",
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
                    color: "#8892A4",
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
                  borderColor: "#080C12",
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
                    color: "#8892A4",
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
                  labels: { color: "#8892A4", boxWidth: 12 },
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
                  labels: { color: "#8892A4", boxWidth: 12 },
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
                  ticks: { color: "#8892A4", font: { size: 10 } },
                },
                y: {
                  grid: { color: GRID },
                  ticks: {
                    color: "#5A6A80",
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
                borderColor: "#080C12",
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
                  color: "#8892A4",
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
        if (tq && !JSON.stringify(t).toLowerCase().includes(tq.toLowerCase()))
          return false;
        return true;
      })
    : [];
  const tabs = [
    { id: "overview", l: "Overview" },
    { id: "sites", l: "Sites & Machines" },
    { id: "products", l: "Products" },
    { id: "eid", l: "Eid Analysis" },
    { id: "payments", l: "Payments" },
    { id: "transactions", l: "Transactions" },
    { id: "commercial", l: "Commercial" },
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
          <div className="nb">
            VOX<span style={{ color: MERC }}>MCC</span> /{" "}
            <span style={{ color: MIRD }}>VOXMM</span>
          </div>
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
          <span style={{ color: "#5A6A80", fontSize: 11 }}>to</span>
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
            <span style={{ fontSize: 10, color: "#5A6A80" }}>
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
            <span style={{ color: "#8892A4" }}>
              {"\u2014"} Payment columns show {"\u201C\u2014\u201D"} until
              adyen_transactions updated.
            </span>
          </div>
        )}
        {D && ha && (
          <div
            style={{
              background: "#0D1117",
              borderBottom: "1px solid #1E2D42",
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
                color: "#5A6A80",
                textTransform: "uppercase",
                letterSpacing: ".1em",
                fontSize: 10,
              }}
            >
              Payment Default
            </span>
            <span style={{ color: "#8892A4" }}>
              Total <strong style={{ color: "#E8EDF5" }}>{aed(ts)}</strong>
            </span>
            <span style={{ color: "#2D3748" }}>|</span>
            <span style={{ color: "#8892A4" }}>
              Captured{" "}
              <strong style={{ color: "#10B981" }}>
                {aed(S?.matched_captured ?? 0)}
              </strong>
            </span>
            <span style={{ color: "#2D3748" }}>|</span>
            <span style={{ color: "#8892A4" }}>
              Gap <strong style={{ color: "#EF4444" }}>{aed(gp)}</strong>
            </span>
            <span style={{ color: "#2D3748" }}>|</span>
            <span style={{ color: "#8892A4" }}>
              Default{" "}
              <strong style={{ color: "#F59E0B", fontSize: 14 }}>{dp}%</strong>
            </span>
            <span style={{ color: "#2D3748" }}>|</span>
            <span style={{ color: "#5A6A80", fontSize: 10 }}>
              {S?.disc_count ?? 0} discrepancies {"\u00B7"}{" "}
              {S?.matched_txns ?? 0}/{S?.total_txns ?? 0} matched
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
                background: "#1E2D42",
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
          <div style={{ padding: 60, textAlign: "center", color: "#5A6A80" }}>
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
                  <h2>VOX Cinema Vending {"\u2014"} Consumer Report</h2>
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
                                {MACHINE_LABELS[m.machine] || m.machine}
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
                                style={{ fontWeight: 600, color: "#E8EDF5" }}
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
                                      background: "#1E2D42",
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
                                      color: "#8892A4",
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

            {tab === "eid" && (
              <div className="pg">
                <div style={{ marginBottom: 20 }}>
                  <div className="sl">Eid Al-Fitr 2026</div>
                  <h2>Holiday Traffic Analysis</h2>
                </div>
                {(() => {
                  const dm: Record<string, Record<string, number>> = {};
                  D.daily.forEach((r) => {
                    if (!dm[r.date]) dm[r.date] = {};
                    dm[r.date][r.site] = r.amount;
                  });
                  const pk = ["2026-03-20", "2026-03-21", "2026-03-22"],
                    po = ["2026-03-23", "2026-03-24", "2026-03-25"];
                  const pM = pk.reduce((s, d) => s + (dm[d]?.Mercato || 0), 0),
                    pMi = pk.reduce((s, d) => s + (dm[d]?.Mirdif || 0), 0),
                    oM = po.reduce((s, d) => s + (dm[d]?.Mercato || 0), 0),
                    oMi = po.reduce((s, d) => s + (dm[d]?.Mirdif || 0), 0);
                  return (
                    <>
                      <div className="gr g2" style={{ marginBottom: 14 }}>
                        <div className="kp km">
                          <div className="kl">
                            Mercato Peak (20{"\u2013"}22 Mar)
                          </div>
                          <div className="kv vm">{aed(pM)}</div>
                          <div className="ks">Post: {aed(oM)}</div>
                        </div>
                        <div className="kp ki">
                          <div className="kl">
                            Mirdif Peak (20{"\u2013"}22 Mar)
                          </div>
                          <div className="kv vi">{aed(pMi)}</div>
                          <div className="ks">Post: {aed(oMi)}</div>
                        </div>
                      </div>
                      <div className="eb">
                        <h4>{"\uD83C\uDF89"} Eid Weekend Insight</h4>
                        <p
                          style={{
                            fontSize: 12,
                            color: "var(--grey2)",
                            lineHeight: 1.7,
                          }}
                        >
                          Combined peak:{" "}
                          <strong style={{ color: "#E8EDF5" }}>
                            {aed(pM + pMi)}
                          </strong>
                          . {pMi > pM ? "Mirdif led" : "Mercato led"}:{" "}
                          <strong style={{ color: MIRD }}>{aed(pMi)}</strong> vs{" "}
                          <strong style={{ color: MERC }}>{aed(pM)}</strong>.
                          Drop:{" "}
                          {pM + pMi > 0
                            ? ((1 - (oM + oMi) / (pM + pMi)) * 100).toFixed(0)
                            : 0}
                          %.
                        </p>
                      </div>
                    </>
                  );
                })()}
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
                {D.transactions.some((t2) => t2.disc) && (
                  <div
                    className="cd"
                    style={{
                      marginBottom: 14,
                      background: "rgba(239,68,68,0.06)",
                      borderColor: "rgba(239,68,68,0.3)",
                    }}
                  >
                    <span style={{ color: "var(--red)", fontWeight: 600 }}>
                      {"\u26A0"} {D.transactions.filter((t2) => t2.disc).length}{" "}
                      Discrepancies
                    </span>
                  </div>
                )}
                <div className="fb">
                  {["all", ...pods].map((s) => (
                    <button
                      key={s}
                      className={`fn ${s === "Mirdif" ? "mb" : ""} ${tsf === s ? "a" : ""}`}
                      onClick={() => setTsf(s)}
                    >
                      {s === "all" ? "All Sites" : s}
                    </button>
                  ))}
                  {["all", "DEBIT", "CREDIT", "PREPAID"].map((f) => (
                    <button
                      key={f}
                      className={`fn ${tff === f ? "a" : ""}`}
                      onClick={() => setTff(f)}
                    >
                      {f === "all"
                        ? "All Funding"
                        : f.charAt(0) + f.slice(1).toLowerCase()}
                    </button>
                  ))}
                  <div className="fs" />
                  <input
                    type="text"
                    placeholder="Search&hellip;"
                    value={tq}
                    onChange={(e) => setTq(e.target.value)}
                  />
                  <span className="cl">
                    {ft.length}/{D.transactions.length}
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
                      {ft.map((t2, i) => (
                        <tr key={i} className={t2.disc ? "dc" : ""}>
                          <td
                            style={{
                              fontSize: 11,
                              color: "#8892A4",
                              whiteSpace: "nowrap",
                            }}
                          >
                            {t2.date}
                          </td>
                          <td style={{ fontSize: 11, color: "#5A6A80" }}>
                            {t2.time}
                          </td>
                          <td
                            className="tm"
                            style={{
                              color: t2.site === "Mercato" ? MERC : MIRD,
                            }}
                          >
                            {MACHINE_LABELS[t2.machine] || t2.machine}
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
                              <span style={{ color: "#2D3748" }}>
                                {"\u2014"}
                              </span>
                            )}
                          </td>
                          <td
                            className="c"
                            style={{
                              fontSize: 10,
                              color:
                                t2.card === "\u2014" ? "#2D3748" : "#8892A4",
                            }}
                          >
                            {t2.card}
                          </td>
                          <td
                            className="c"
                            style={{
                              fontSize: 10,
                              color:
                                t2.wallet === "\u2014" ? "#2D3748" : "#5A6A80",
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
                                      color: "#E8EDF5",
                                      fontWeight: 500,
                                      fontSize: 12,
                                    }
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
                                  : { color: "#8892A4" }
                              }
                            >
                              {ha && t2.captured > 0
                                ? `AED ${t2.captured}`
                                : "\u2014"}
                            </span>
                          </td>
                          <td className="c" style={{ color: "#8892A4" }}>
                            {t2.units}
                          </td>
                          <td
                            style={{
                              fontSize: 11,
                              color: "#8892A4",
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
              </div>
            )}
            {tab === "commercial" && (
              <div className="pg">
                <div style={{ marginBottom: 16 }}>
                  <div className="sl">Financial Reconciliation</div>
                  <h2>VOX Commercial Reconciliation</h2>
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
                                  color: "#E8EDF5",
                                  marginBottom: 4,
                                }}
                              >
                                {k.v}
                              </div>
                              <div style={{ fontSize: 10, color: "#5A6A80" }}>
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
                                <span style={{ color: "#8892A4", flex: 1 }}>
                                  {it.l}
                                </span>
                                <span
                                  style={{ color: "#E8EDF5", fontWeight: 600 }}
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
                                          color: "#8892A4",
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
                                      <div style={{ color: "#5A6A80" }}>
                                        Total
                                      </div>
                                      <div
                                        style={{
                                          color: "#E8EDF5",
                                          textAlign: "right",
                                        }}
                                      >
                                        {aed(s.total_amount)}
                                      </div>
                                      <div style={{ color: "#5A6A80" }}>
                                        Captured
                                      </div>
                                      <div
                                        style={{
                                          color: "#E8EDF5",
                                          textAlign: "right",
                                        }}
                                      >
                                        {aed(s.captured_amount)}
                                      </div>
                                      <div style={{ color: "#5A6A80" }}>
                                        Net Revenue
                                      </div>
                                      <div
                                        style={{
                                          color: "#E8EDF5",
                                          textAlign: "right",
                                        }}
                                      >
                                        {aed(s.net_revenue)}
                                      </div>
                                      <div style={{ color: "#5A6A80" }}>
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
                                      <div style={{ color: "#5A6A80" }}>
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
                                      <div style={{ color: "#5A6A80" }}>
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
                              <div style={{ color: "#5A6A80" }}>
                                Boonz 20% Share
                              </div>
                              <div
                                style={{ color: "#F59E0B", fontWeight: 600 }}
                              >
                                {aed(w.boonz_share)}
                              </div>
                              <div style={{ color: "#5A6A80" }}>Boonz COGS</div>
                              <div
                                style={{ color: "#EF4444", fontWeight: 600 }}
                              >
                                {aed(w.boonz_cogs)}
                              </div>
                              <div
                                style={{
                                  color: "#E8EDF5",
                                  fontWeight: 600,
                                  borderTop: "1px solid var(--border)",
                                  paddingTop: 6,
                                }}
                              >
                                Total Receipts
                              </div>
                              <div
                                style={{
                                  color: "#E8EDF5",
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
                          <div
                            style={{
                              padding: "12px 16px",
                              borderBottom: "1px solid var(--border)",
                              fontSize: 11,
                              color: "var(--grey)",
                              textTransform: "uppercase",
                              letterSpacing: 1,
                            }}
                          >
                            Transaction Detail {"\u00B7"}{" "}
                            {C.transactions.length} rows
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
                                {C.transactions.map((t, i) => {
                                  const isDisc =
                                    Number(t.default_amount || 0) > 0;
                                  const isUnmatched = !t.matched_adyen;
                                  const rowStyle: React.CSSProperties = {
                                    ...(isDisc
                                      ? { background: "rgba(239,68,68,0.06)" }
                                      : {}),
                                    ...(isUnmatched ? { opacity: 0.6 } : {}),
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
                                      ? "#8892A4"
                                      : "#10B981";
                                  return (
                                    <tr key={i} style={rowStyle}>
                                      <td
                                        style={{
                                          fontSize: 11,
                                          color: "#8892A4",
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
                                        style={{ color: isMerc ? MERC : MIRD }}
                                      >
                                        {MACHINE_LABELS[t.machine] || t.machine}
                                      </td>
                                      <td
                                        style={{
                                          fontSize: 11,
                                          color: "#8892A4",
                                          maxWidth: 220,
                                        }}
                                      >
                                        {t.items}
                                      </td>
                                      <td
                                        className="c"
                                        style={{ color: "#8892A4" }}
                                      >
                                        {t.units}
                                      </td>
                                      <td
                                        className="r"
                                        style={{
                                          color: "#E8EDF5",
                                          fontSize: 11,
                                        }}
                                      >
                                        {aed2(t.total_amount)}
                                      </td>
                                      <td
                                        className="r"
                                        style={{
                                          color: "#8892A4",
                                          fontSize: 11,
                                        }}
                                      >
                                        {aed2(t.captured_amount)}
                                      </td>
                                      <td
                                        className="r"
                                        style={{
                                          color: isDisc ? "#EF4444" : "#2D3748",
                                          fontSize: 11,
                                          fontWeight: isDisc ? 700 : 400,
                                        }}
                                      >
                                        {isDisc
                                          ? aed2(t.default_amount)
                                          : "\u2014"}
                                      </td>
                                      <td
                                        className="r"
                                        style={{
                                          color:
                                            Number(t.refunded_amount) > 0
                                              ? "#EC4899"
                                              : "#2D3748",
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
                                          color: "#8892A4",
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
                                          color: "#8892A4",
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
                        </div>
                      </>
                    );
                  })()}
              </div>
            )}
          </>
        )}
        <footer>
          VOX Cinema Vending {"\u00B7"} Consumer Report {"\u00B7"} Boonz Smart
          Vending {"\u00B7"} Supabase (Weimi + Adyen)
        </footer>
      </div>
    </>
  );
}
