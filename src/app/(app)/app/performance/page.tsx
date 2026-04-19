"use client";

import { useState, useEffect, useCallback, useMemo, useRef } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  CartesianGrid,
  LineChart,
  Line,
  ScatterChart,
  Scatter,
  ZAxis,
  Cell,
  LabelList,
  PieChart,
  Pie,
  Legend,
} from "recharts";

// ── constants ──
const font = "'Plus Jakarta Sans', sans-serif";
const TABS = [
  "Overview",
  "Sites & Machines",
  "Products",
  "Payments",
  "Transactions",
  "Commercial",
] as const;
type Tab = (typeof TABS)[number];
const GROUPS = [
  "All",
  "ADDMIND",
  "INDEPENDENT",
  "OHMYDESK",
  "VML",
  "VOX",
  "WPP",
] as const;
type GroupFilter = (typeof GROUPS)[number];
const ADYEN_FEE_PCT = 0.0475;
const BOONZ_SHARE_PCT = 0.2;
// B2: only these Adyen statuses count as real captured revenue.
// Everything else (Refused, RefundedBulk, cancellation states, etc.)
// is either reversed, pending, or explicitly refused — not settled.
const SETTLED_STATUSES: ReadonlySet<string> = new Set([
  "SettledBulk",
  "SentForSettle",
  "Captured",
  "AuthorisedBulk",
]);
const PAGE_SIZE = 50;

// ── commercial scenario constants ──
const OPEX_PCT = 0; // placeholder — Opex line currently renders as AED 0
const GRIT_OMD_PARTNER_SHARE = 0.05;
const GRIT_OMD_BOONZ_SHARE = 0.95;

// B3: legacy hardcoded machine-ID sets below are no longer the source
// of truth. Kept only so old code paths still type-check while the
// refactor lands; actual scenario math is driven by
// resolveAgreement(activeGroup, selectedMachineIds, machineList, agreementByGroup).
const VOX_MACHINE_IDS = new Set<string>([
  "148c4fcf-b794-43f0-a2a8-e6f17605b045", // VOXMCC-1009-0201-B0
  "b9f0c828-bcd1-493a-ac28-934f5dba0872", // VOXMCC-1011-0101-B0
  "5b8fc451-741f-48e6-9eba-54a61d312167", // VOXMCC-1012-0100-V0
  "df4f3c4b-6c38-4e45-b536-19389d4fed31", // VOXMCC-1017-0200-V0
  "bd94970e-40d6-49fd-a532-1fd1e758ffda", // VOXMM-1009-0100-V0
  "bb9578ea-9aba-404e-881d-ea239f8609ce", // VOXMM-1013-0101-B0
]);

const GRIT_OMD_MACHINE_IDS = new Set<string>([
  "7a8e5711-7acb-48a7-9809-ca1324976855", // GRIT-1022-0100-W0
  "822d386f-e0db-4a51-b201-0731df90f393", // OMDBB-1020-0P00-O1
  "5ac54ef6-b25d-48ae-a292-070871621e03", // OMDCW-1021-0100-W0
]);

// B3: legacy scenario type. Still used as the shape key for waterfall
// step selection below (VOX / REVENUE_SHARE / NONE map to the same
// 9 / 7 / 3-step shapes that VOX / GRIT_OMD / STANDARD did before).
type CommercialScenario = "VOX" | "GRIT_OMD" | "STANDARD";

function detectScenario(selectedIds: string[]): CommercialScenario {
  if (selectedIds.length === 0) return "STANDARD";
  const allVox = selectedIds.every((id) => VOX_MACHINE_IDS.has(id));
  if (allVox) return "VOX";
  const allGritOmd = selectedIds.every((id) => GRIT_OMD_MACHINE_IDS.has(id));
  if (allGritOmd) return "GRIT_OMD";
  return "STANDARD";
}

// B3: DB-driven agreement resolution. Replaces the hardcoded machine-ID
// based detectScenario. Called from the component body with state.
type Agreement = {
  type: "VOX" | "REVENUE_SHARE" | "NONE";
  boonz: number;
  partner: number;
  partnerName: string | null;
};
const DEFAULT_AGREEMENT: Agreement = {
  type: "NONE",
  boonz: 1.0,
  partner: 0.0,
  partnerName: null,
};
function resolveAgreement(
  activeGroup: string | null,
  selectedMachineIds: string[],
  machineList: Array<{ machine_id: string; venue_group?: string | null }>,
  agreementByGroup: Record<string, Agreement>,
): Agreement {
  let venueGroups: string[] = [];

  if (activeGroup && activeGroup !== "All") {
    venueGroups = [activeGroup];
  } else if (selectedMachineIds.length > 0) {
    const sel = machineList.filter((m) =>
      selectedMachineIds.includes(m.machine_id),
    );
    venueGroups = [
      ...new Set(sel.map((m) => m.venue_group).filter(Boolean) as string[]),
    ];
  } else {
    // All machines, no specific group — mixed tenants, show no agreement
    return DEFAULT_AGREEMENT;
  }

  if (venueGroups.length === 0) return DEFAULT_AGREEMENT;
  const resolved = venueGroups.map(
    (g) => agreementByGroup[g] ?? DEFAULT_AGREEMENT,
  );
  const first = resolved[0];
  const allSame = resolved.every((a) => a.type === first.type);
  return allSame ? first : DEFAULT_AGREEMENT;
}

type WaterfallStepType = "total" | "subtract" | "subtotal";
interface WaterfallStep {
  label: string;
  value: number; // positive for totals/subtotals; negative for subtracts
  type: WaterfallStepType;
}
interface WaterfallBar {
  name: string;
  base: number;
  value: number;
  fill: string;
}

function buildWaterfallBars(steps: WaterfallStep[]): WaterfallBar[] {
  const bars: WaterfallBar[] = [];
  let running = 0;
  for (const step of steps) {
    if (step.type === "total") {
      bars.push({
        name: step.label,
        base: 0,
        value: Math.round(Math.max(0, step.value)),
        fill: "#0F4D3A",
      });
      running = step.value;
    } else if (step.type === "subtotal") {
      bars.push({
        name: step.label,
        base: 0,
        value: Math.round(Math.max(0, step.value)),
        fill: "#0E3F4D",
      });
      running = step.value;
    } else {
      // subtract: value is negative; draw red bar from (running - deduction) up to running
      const deduction = Math.abs(step.value);
      const newRunning = running + step.value;
      bars.push({
        name: step.label,
        base: Math.round(Math.max(0, newRunning)),
        value: Math.round(deduction),
        fill: "#DC2626",
      });
      running = newRunning;
    }
  }
  return bars;
}

const GROUP_COLORS: Record<string, string> = {
  ADDMIND: "#2563eb",
  INDEPENDENT: "#16a34a",
  OHMYDESK: "#9333ea",
  VML: "#dc2626",
  VOX: "#d97706",
  WPP: "#0891b2",
};

// ── types ──
interface SaleRow {
  transaction_id: string;
  machine_id: string;
  transaction_date: string;
  total_amount: number;
  cost_amount: number | null;
  paid_amount: number;
  qty: number;
  pod_product_name: string | null;
  boonz_product_id: string | null;
  delivery_status: string | null;
  product_cost: number | null;
  actual_selling_price: number | null;
  internal_txn_sn: string | null;
  machines: { official_name: string; venue_group: string | null } | null;
}

interface AdyenTxn {
  adyen_txn_id: string;
  machine_id: string;
  creation_date: string;
  value_aed: number | null;
  captured_amount_value: number | null;
  status: string | null;
  payment_method: string | null;
  funding_source: string | null;
  store_description: string | null;
  psp_reference: string | null;
  merchant_reference: string | null;
}

interface MachineInfo {
  machine_id: string;
  official_name: string;
  venue_group: string | null;
  status: string | null;
}

// ── helpers ──
function fmtN(n: number): string {
  return n.toLocaleString("en", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  });
}
function fmtAed(n: number): string {
  return (
    "AED " +
    n.toLocaleString("en", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })
  );
}
function pct(part: number, whole: number): string {
  return whole > 0 ? ((part / whole) * 100).toFixed(0) + "%" : "0%";
}
function daysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return d.toISOString().split("T")[0];
}

const cblStyle: React.CSSProperties = {
  fontSize: 10,
  color: "#6b6860",
  textTransform: "uppercase",
  letterSpacing: "0.1em",
};
const dateStyle: React.CSSProperties = {
  padding: "5px 10px",
  borderRadius: 4,
  border: "1px solid #e8e4de",
  background: "#ffffff",
  color: "#0a0a0a",
  fontSize: 11,
  fontFamily: font,
  outline: "none",
};

// ── section label ──
function SectionLabel({ text }: { text: string }) {
  return (
    <div
      style={{
        fontSize: 10,
        letterSpacing: "0.12em",
        textTransform: "uppercase",
        color: "#6b6860",
        marginBottom: 14,
        display: "flex",
        alignItems: "center",
        gap: 10,
      }}
    >
      {text}
      <span style={{ flex: 1, height: 1, background: "#e8e4de" }} />
    </div>
  );
}

// ── stat card ──
function StatCard({
  label,
  value,
  subtitle,
  accent,
  valueColor,
}: {
  label: string;
  value: string;
  subtitle?: string;
  accent: string;
  valueColor?: string;
}) {
  return (
    <div
      style={{
        background: "white",
        border: "1px solid #e8e4de",
        borderRadius: 6,
        padding: "16px 18px",
        position: "relative",
        overflow: "hidden",
      }}
    >
      <div
        style={{
          position: "absolute",
          top: 0,
          left: 0,
          right: 0,
          height: 2,
          background: accent,
        }}
      />
      <div
        style={{
          fontSize: 10,
          letterSpacing: "0.08em",
          textTransform: "uppercase",
          color: "#6b6860",
          marginBottom: 8,
        }}
      >
        {label}
      </div>
      <div
        style={{
          fontSize: 26,
          fontWeight: 800,
          letterSpacing: "-1px",
          lineHeight: 1,
          color: valueColor || accent,
          fontFamily: font,
        }}
      >
        {value}
      </div>
      {subtitle && (
        <div style={{ fontSize: 10, color: "#6b6860", marginTop: 6 }}>
          {subtitle}
        </div>
      )}
    </div>
  );
}

// ── progress bar ──
function ProgressRow({
  label,
  value,
  max,
  color,
  display,
}: {
  label: string;
  value: number;
  max: number;
  color: string;
  display: string;
}) {
  const w = max > 0 ? (value / max) * 100 : 0;
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 10,
        marginBottom: 8,
      }}
    >
      <span
        style={{
          fontSize: 11,
          color: "#9a948e",
          width: 140,
          whiteSpace: "nowrap",
          overflow: "hidden",
          textOverflow: "ellipsis",
          flexShrink: 0,
        }}
      >
        {label}
      </span>
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
            height: "100%",
            borderRadius: 2,
            width: `${w}%`,
            background: color,
            transition: "width .8s ease",
          }}
        />
      </div>
      <span
        style={{
          fontSize: 11,
          color: "#0a0a0a",
          width: 72,
          textAlign: "right",
          fontWeight: 500,
          flexShrink: 0,
        }}
      >
        {display}
      </span>
      <span
        style={{
          fontSize: 10,
          color: "#6b6860",
          width: 36,
          textAlign: "right",
          flexShrink: 0,
        }}
      >
        {pct(value, max)}
      </span>
    </div>
  );
}

// ── main component ──
export default function PerformancePage() {
  const [activeTab, setActiveTab] = useState<Tab>("Overview");
  const [dateFrom, setDateFrom] = useState(daysAgo(30));
  const [dateTo, setDateTo] = useState(new Date().toISOString().split("T")[0]);
  const [group, setGroup] = useState<GroupFilter>("All");
  const [viewMode, setViewMode] = useState<"consolidated" | "by-group">(
    "consolidated",
  );
  const [selectedMachineIds, setSelectedMachineIds] = useState<string[]>([]);
  const [machineDropdownOpen, setMachineDropdownOpen] = useState(false);
  const machineDropdownRef = useRef<HTMLDivElement | null>(null);
  const [loading, setLoading] = useState(true);
  const [lastUpdated, setLastUpdated] = useState<string | null>(null);

  const [salesRows, setSalesRows] = useState<SaleRow[]>([]);
  const [adyenRows, setAdyenRows] = useState<AdyenTxn[]>([]);
  const [machineList, setMachineList] = useState<MachineInfo[]>([]);
  // B3: DB-driven commercial agreements (venue_group → boonz/partner split).
  // Keyed by venue_group. Empty {} until the initial fetch resolves.
  const [agreementByGroup, setAgreementByGroup] = useState<
    Record<
      string,
      {
        type: "VOX" | "REVENUE_SHARE" | "NONE";
        boonz: number;
        partner: number;
        partnerName: string | null;
      }
    >
  >({});

  // transactions tab state
  const [txnPage, setTxnPage] = useState(0);
  const [txnSearch, setTxnSearch] = useState("");
  const [txnGroup, setTxnGroup] = useState<GroupFilter>("All");
  const [txnFunding, setTxnFunding] = useState("All");

  // ── fetch data ──
  const fetchData = useCallback(async () => {
    setLoading(true);
    try {
      const supabase = createClient();

      let salesQuery = supabase
        .from("sales_history")
        .select(
          "transaction_id, machine_id, transaction_date, total_amount, cost_amount, paid_amount, qty, pod_product_name, boonz_product_id, delivery_status, product_cost, actual_selling_price, internal_txn_sn, machines!inner(official_name, venue_group)",
        )
        .eq("delivery_status", "Successful")
        .gte("transaction_date", `${dateFrom}T00:00:00+00:00`)
        .lte("transaction_date", `${dateTo}T23:59:59+00:00`);
      if (selectedMachineIds.length > 0) {
        salesQuery = salesQuery.in("machine_id", selectedMachineIds);
      }

      let adyenQuery = supabase
        .from("adyen_transactions")
        .select(
          "adyen_txn_id, machine_id, creation_date, value_aed, captured_amount_value, status, payment_method, funding_source, store_description, psp_reference, merchant_reference",
        )
        .gte("creation_date", `${dateFrom}T00:00:00+00:00`)
        .lte("creation_date", `${dateTo}T23:59:59+00:00`);
      if (selectedMachineIds.length > 0) {
        adyenQuery = adyenQuery.in("machine_id", selectedMachineIds);
      }

      const [machineRes, salesRes, adyenRes, agreementsRes] = await Promise.all(
        [
          supabase
            .from("machines")
            .select("machine_id, official_name, venue_group, status")
            .order("official_name")
            .limit(10000),
          salesQuery.limit(10000),
          adyenQuery.limit(10000),
          supabase
            .from("commercial_agreements")
            .select(
              "venue_group, agreement_type, boonz_share_pct, partner_share_pct, partner_name",
            )
            .limit(10000),
        ],
      );

      // B3: build the venue_group → agreement map. Rows with unknown types
      // fall through to NONE at render time via DEFAULT_AGREEMENT.
      const agreementMap: Record<
        string,
        {
          type: "VOX" | "REVENUE_SHARE" | "NONE";
          boonz: number;
          partner: number;
          partnerName: string | null;
        }
      > = {};
      for (const a of agreementsRes.data ?? []) {
        const t = (a.agreement_type as string) ?? "NONE";
        agreementMap[a.venue_group as string] = {
          type:
            t === "VOX" || t === "REVENUE_SHARE" || t === "NONE" ? t : "NONE",
          boonz: Number(a.boonz_share_pct ?? 1),
          partner: Number(a.partner_share_pct ?? 0),
          partnerName: (a.partner_name as string | null) ?? null,
        };
      }
      setAgreementByGroup(agreementMap);

      const machines = (machineRes.data ?? []) as MachineInfo[];
      setMachineList(machines);

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      let filtered = (salesRes.data ?? []) as any as SaleRow[];
      if (group !== "All") {
        filtered = filtered.filter((r) => r.machines?.venue_group === group);
      }
      setSalesRows(filtered);

      let filteredAdyen = (adyenRes.data ?? []) as AdyenTxn[];
      if (group !== "All") {
        const machineIds = new Set(
          machines
            .filter((m) => m.venue_group === group)
            .map((m) => m.machine_id),
        );
        filteredAdyen = filteredAdyen.filter((r) =>
          machineIds.has(r.machine_id),
        );
      }
      setAdyenRows(filteredAdyen);

      setLastUpdated(
        new Date().toLocaleTimeString("en-GB", {
          hour: "2-digit",
          minute: "2-digit",
        }),
      );
    } catch (e) {
      console.error("Fetch error:", e);
    } finally {
      setLoading(false);
    }
  }, [dateFrom, dateTo, group, selectedMachineIds]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Close machine dropdown when clicking outside
  useEffect(() => {
    if (!machineDropdownOpen) return;
    const handler = (e: MouseEvent) => {
      if (
        machineDropdownRef.current &&
        !machineDropdownRef.current.contains(e.target as Node)
      ) {
        setMachineDropdownOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [machineDropdownOpen]);

  // Machines available in the dropdown (Active + not warehouse)
  const dropdownMachines = useMemo(
    () =>
      machineList
        .filter(
          (m) =>
            m.status === "Active" && !(m.official_name || "").startsWith("WH"),
        )
        .sort((a, b) =>
          (a.official_name || "").localeCompare(b.official_name || ""),
        ),
    [machineList],
  );

  // B3: DB-driven agreement resolution (venue_group → boonz/partner split).
  // Source of truth for all scenario math below.
  const activeAgreement = useMemo(
    () =>
      resolveAgreement(
        group,
        selectedMachineIds,
        machineList,
        agreementByGroup,
      ),
    [group, selectedMachineIds, machineList, agreementByGroup],
  );
  // Kept as the shape key for waterfall + per-scenario layout switches.
  // Maps DB agreement type → legacy shape label (VOX / REVENUE_SHARE → 7
  // steps like GRIT_OMD used to; NONE → 3 steps like STANDARD).
  const commercialScenario: CommercialScenario =
    activeAgreement.type === "VOX"
      ? "VOX"
      : activeAgreement.type === "REVENUE_SHARE"
        ? "GRIT_OMD"
        : "STANDARD";

  const toggleMachineId = (id: string) => {
    setSelectedMachineIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id],
    );
  };

  const handleRefresh = () => {
    fetchData();
  };

  // ── computed values ──
  const totalWeimi = useMemo(
    () => salesRows.reduce((s, r) => s + (r.total_amount || 0), 0),
    [salesRows],
  );
  const settledAdyen = useMemo(
    () => adyenRows.filter((r) => SETTLED_STATUSES.has(r.status ?? "")),
    [adyenRows],
  );
  const capturedAdyen = useMemo(
    () => settledAdyen.reduce((s, r) => s + (r.captured_amount_value || 0), 0),
    [settledAdyen],
  );

  // ── Correct payment default: match by merchant_reference, not machine+date ──
  // Each Adyen merchant_reference equals base_txn_sn (internal_txn_sn with
  // trailing _N suffix stripped). Only transactions with a settled Adyen match
  // are counted — unmatched rows (no Adyen record yet) are NOT flagged as defaults.
  const adyenByMerchantRef = useMemo(() => {
    const m = new Map<string, AdyenTxn>();
    for (const a of adyenRows) {
      if (a.merchant_reference) m.set(a.merchant_reference, a);
    }
    return m;
  }, [adyenRows]);

  const txnMatchStats = useMemo(() => {
    // Group individual sales lines into basket-level transactions
    const groups = new Map<string, { total: number }>();
    for (const s of salesRows) {
      const base = (s.internal_txn_sn ?? "").replace(/_\d+$/, "");
      if (!base) continue;
      // Mirror the RPC's vox_sales filter: skip zero-amount rows (cash /
      // cancelled-before-capture). They inflate basket count and distort the rate.
      const effectiveTotal = (s.total_amount ?? 0) > 0
        ? (s.total_amount ?? 0)
        : (s.paid_amount ?? 0);
      if (effectiveTotal <= 0) continue;
      const g = groups.get(base);
      if (g) { g.total += effectiveTotal; }
      else groups.set(base, { total: effectiveTotal });
    }
    let matchedTotal = 0;
    let matchedCount = 0;
    let defaultGap = 0;
    for (const [base, grp] of groups) {
      const adyen = adyenByMerchantRef.get(base);
      if (adyen && SETTLED_STATUSES.has(adyen.status ?? "")) {
        matchedTotal += grp.total;
        matchedCount++;
        defaultGap += Math.max(grp.total - (adyen.captured_amount_value || 0), 0);
      }
    }
    return {
      matchedCount,
      totalCount: groups.size,
      gap: defaultGap,
      defaultPct: matchedTotal > 0 ? (defaultGap / matchedTotal) * 100 : 0,
    };
  }, [salesRows, adyenByMerchantRef]);

  const gap = txnMatchStats.gap;
  const defaultPct = txnMatchStats.defaultPct;
  const matchedCount = txnMatchStats.matchedCount;
  const totalCount = txnMatchStats.totalCount;
  const totalCogs = useMemo(
    () => salesRows.reduce((s, r) => s + (r.product_cost || 0), 0),
    [salesRows],
  );
  const totalUnits = useMemo(
    () => salesRows.reduce((s, r) => s + (r.qty || 0), 0),
    [salesRows],
  );

  // ── daily data ──
  const dailyData = useMemo(() => {
    const map: Record<string, number> = {};
    salesRows.forEach((r) => {
      const d = r.transaction_date?.split("T")[0] ?? "";
      if (d) map[d] = (map[d] || 0) + (r.total_amount || 0);
    });
    return Object.entries(map)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([date, amount]) => ({
        date: date.slice(5),
        amount: Math.round(amount),
      }));
  }, [salesRows]);

  // ── weekly data ──
  const weeklyData = useMemo(() => {
    const weekKey = (date: Date): string => {
      const d = new Date(
        Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()),
      );
      const dayNum = d.getUTCDay() || 7;
      d.setUTCDate(d.getUTCDate() + 4 - dayNum);
      const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
      const weekNo = Math.ceil(
        ((d.getTime() - yearStart.getTime()) / 86400000 + 1) / 7,
      );
      return `${d.getUTCFullYear()}-W${String(weekNo).padStart(2, "0")}`;
    };
    const map: Record<string, number> = {};
    salesRows.forEach((r) => {
      const d = new Date(r.transaction_date);
      const key = weekKey(d);
      map[key] = (map[key] || 0) + (r.total_amount || 0);
    });
    return Object.entries(map)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, amount]) => ({
        week: "W" + key.split("-W")[1],
        amount: Math.round(amount),
      }));
  }, [salesRows]);

  // ── hourly data ──
  const hourlyData = useMemo(() => {
    const map: Record<number, number> = {};
    salesRows.forEach((r) => {
      const h = new Date(r.transaction_date).getHours();
      map[h] = (map[h] || 0) + (r.total_amount || 0);
    });
    return Array.from({ length: 24 }, (_, i) => ({
      hour: `${i}h`,
      amount: Math.round(map[i] || 0),
    }));
  }, [salesRows]);

  // ── day of week data ──
  const dowData = useMemo(() => {
    const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const map: Record<number, number> = {};
    salesRows.forEach((r) => {
      const d = new Date(r.transaction_date).getDay();
      map[d] = (map[d] || 0) + (r.total_amount || 0);
    });
    return days.map((name, i) => ({
      day: name,
      amount: Math.round(map[i] || 0),
    }));
  }, [salesRows]);

  // ── group data ──
  const groupData = useMemo(() => {
    const map: Record<
      string,
      {
        revenue: number;
        units: number;
        txns: number;
        cogs: number;
        machines: Set<string>;
      }
    > = {};
    salesRows.forEach((r) => {
      const g = r.machines?.venue_group || "Unknown";
      if (!map[g])
        map[g] = {
          revenue: 0,
          units: 0,
          txns: 0,
          cogs: 0,
          machines: new Set(),
        };
      map[g].revenue += r.total_amount || 0;
      map[g].units += r.qty || 0;
      map[g].txns += 1;
      map[g].cogs += r.product_cost || 0;
      map[g].machines.add(r.machine_id);
    });
    return Object.entries(map)
      .sort(([, a], [, b]) => b.revenue - a.revenue)
      .map(([name, d]) => ({
        name,
        revenue: d.revenue,
        units: d.units,
        txns: d.txns,
        cogs: d.cogs,
        machineCount: d.machines.size,
      }));
  }, [salesRows]);

  // ── machine data ──
  const machineData = useMemo(() => {
    const map: Record<
      string,
      {
        revenue: number;
        units: number;
        txns: number;
        name: string;
        group: string;
      }
    > = {};
    salesRows.forEach((r) => {
      const id = r.machine_id;
      if (!map[id])
        map[id] = {
          revenue: 0,
          units: 0,
          txns: 0,
          name: r.machines?.official_name || id,
          group: r.machines?.venue_group || "Unknown",
        };
      map[id].revenue += r.total_amount || 0;
      map[id].units += r.qty || 0;
      map[id].txns += 1;
    });
    return Object.entries(map)
      .sort(([, a], [, b]) => b.revenue - a.revenue)
      .map(([id, d]) => ({ id, ...d }));
  }, [salesRows]);

  // ── product data ──
  const productData = useMemo(() => {
    const map: Record<
      string,
      { revenue: number; units: number; txns: number; groups: Set<string> }
    > = {};
    salesRows.forEach((r) => {
      const name = r.pod_product_name || r.boonz_product_id || "Unknown";
      if (!map[name])
        map[name] = { revenue: 0, units: 0, txns: 0, groups: new Set() };
      map[name].revenue += r.total_amount || 0;
      map[name].units += r.qty || 0;
      map[name].txns += 1;
      if (r.machines?.venue_group) map[name].groups.add(r.machines.venue_group);
    });
    return Object.entries(map)
      .sort(([, a], [, b]) => b.revenue - a.revenue)
      .map(([name, d]) => ({
        name,
        revenue: d.revenue,
        units: d.units,
        txns: d.txns,
        avgPrice: d.units > 0 ? d.revenue / d.units : 0,
        groups: Array.from(d.groups),
      }));
  }, [salesRows]);

  // ── payment data ──
  const paymentStats = useMemo(() => {
    const totalCaptured = settledAdyen.reduce(
      (s, r) => s + (r.captured_amount_value || 0),
      0,
    );
    const totalTxns = settledAdyen.length;
    const avgTxn = totalTxns > 0 ? totalCaptured / totalTxns : 0;

    const fundingMap: Record<string, { count: number; amount: number }> = {};
    const methodMap: Record<string, { count: number; amount: number }> = {};
    const statusMap: Record<string, number> = {};

    adyenRows.forEach((r) => {
      const fs = r.funding_source || "Unknown";
      if (!fundingMap[fs]) fundingMap[fs] = { count: 0, amount: 0 };
      fundingMap[fs].count += 1;
      fundingMap[fs].amount += r.captured_amount_value || 0;

      const pm = r.payment_method || "Unknown";
      if (!methodMap[pm]) methodMap[pm] = { count: 0, amount: 0 };
      methodMap[pm].count += 1;
      methodMap[pm].amount += r.captured_amount_value || 0;

      const st = r.status || "Unknown";
      statusMap[st] = (statusMap[st] || 0) + 1;
    });

    return {
      totalCaptured,
      totalTxns,
      avgTxn,
      funding: Object.entries(fundingMap)
        .sort(([, a], [, b]) => b.amount - a.amount)
        .map(([name, d]) => ({ name, ...d })),
      methods: Object.entries(methodMap)
        .sort(([, a], [, b]) => b.amount - a.amount)
        .map(([name, d]) => ({ name, ...d })),
      statuses: Object.entries(statusMap)
        .sort(([, a], [, b]) => b - a)
        .map(([name, count]) => ({ name, count })),
    };
  }, [adyenRows, settledAdyen]);

  // ── group daily trends ──
  const groupDailyTrends = useMemo(() => {
    const result: Record<string, { date: string; amount: number }[]> = {};
    salesRows.forEach((r) => {
      const g = r.machines?.venue_group || "Unknown";
      if (!result[g]) result[g] = [];
      const d = r.transaction_date?.split("T")[0] ?? "";
      const existing = result[g].find((x) => x.date === d);
      if (existing) existing.amount += r.total_amount || 0;
      else result[g].push({ date: d, amount: r.total_amount || 0 });
    });
    for (const g of Object.keys(result)) {
      result[g].sort((a, b) => a.date.localeCompare(b.date));
      result[g] = result[g].map((x) => ({
        ...x,
        amount: Math.round(x.amount),
      }));
    }
    return result;
  }, [salesRows]);

  // ── transactions tab ──
  const filteredTxns = useMemo(() => {
    // Match by merchant_reference (= base_txn_sn) for accurate default detection.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let rows: any[] = salesRows.map((s) => {
      const base = (s.internal_txn_sn ?? "").replace(/_\d+$/, "");
      const matchedAny = base ? adyenByMerchantRef.get(base) : undefined;
      const status = matchedAny?.status ?? null;
      const settled = !!status && SETTLED_STATUSES.has(status);
      return {
        ...s,
        captured: settled ? (matchedAny?.captured_amount_value ?? 0) : 0,
        funding: matchedAny?.funding_source || "",
        adyenStatus: status || "",
        psp: matchedAny?.psp_reference || "",
        paymentMethod: matchedAny?.payment_method || "",
        isWallet: (matchedAny?.funding_source || "").toUpperCase() === "WALLET",
        isDefault: !matchedAny || !settled,
      };
    });
    if (txnGroup !== "All")
      rows = rows.filter((r) => r.machines?.venue_group === txnGroup);
    if (txnFunding === "DEFAULT") {
      rows = rows.filter((r) => r.isDefault);
    } else if (txnFunding !== "All") {
      rows = rows.filter((r) => r.funding === txnFunding);
    }
    if (txnSearch) {
      const q = txnSearch.toLowerCase();
      rows = rows.filter(
        (r) =>
          (r.machines?.official_name || "").toLowerCase().includes(q) ||
          (r.pod_product_name || "").toLowerCase().includes(q) ||
          (r.machine_id || "").toLowerCase().includes(q),
      );
    }
    return rows.sort((a, b) =>
      (b.transaction_date || "").localeCompare(a.transaction_date || ""),
    );
  }, [salesRows, adyenByMerchantRef, txnGroup, txnFunding, txnSearch]);

  // Count of non-zero sales rows with no settled Adyen match — feeds the PAYMENT DEFAULT banner.
  const defaultTxnCount = useMemo(() => {
    let n = 0;
    for (const s of salesRows) {
      const effectiveTotal = (s.total_amount ?? 0) > 0
        ? (s.total_amount ?? 0)
        : (s.paid_amount ?? 0);
      if (effectiveTotal <= 0) continue; // skip cash / cancelled-before-capture
      const base = (s.internal_txn_sn ?? "").replace(/_\d+$/, "");
      const match = base ? adyenByMerchantRef.get(base) : undefined;
      if (!match || !SETTLED_STATUSES.has(match.status ?? "")) n++;
    }
    return n;
  }, [salesRows, adyenByMerchantRef]);

  const txnPageCount = Math.ceil(filteredTxns.length / PAGE_SIZE);
  const txnSlice = filteredTxns.slice(
    txnPage * PAGE_SIZE,
    (txnPage + 1) * PAGE_SIZE,
  );

  // ── commercial data ──
  const commercialData = useMemo(() => {
    // Single source of truth for revenue math. netRevenue is derived from
    // Weimi gross minus refunds and Adyen fees — used by cards, waterfall,
    // and the summary table. No second formula exists.
    const adyenFees = capturedAdyen * ADYEN_FEE_PCT;
    const refunds = adyenRows
      .filter((r) => r.status === "RefundedBulk")
      .reduce((s, r) => s + (r.captured_amount_value || 0), 0);
    const boonzCogs = totalCogs;

    // ── scenario waterfall (drives COMMERCIAL waterfall chart + summary table) ──
    const scenarioGross = totalWeimi;
    const scenarioNet = scenarioGross - refunds - adyenFees;
    const netRevenue = scenarioNet;
    const opex = OPEX_PCT; // 0 — placeholder

    // B3: splits come from the active DB agreement, not hardcoded constants.
    const boonzRevenue = scenarioNet * activeAgreement.boonz;
    const partnerRevenue = scenarioNet * activeAgreement.partner;
    // Back-compat aliases — the waterfall step locals still use these names.
    const voxShare = partnerRevenue;
    const voxBoonzNet = boonzRevenue;
    const voxGrossProfit = voxBoonzNet - totalCogs;
    const voxEbitda = voxGrossProfit - opex;
    const gritPartner = partnerRevenue;
    const gritBoonzNet = boonzRevenue;
    const gritEbitda = gritBoonzNet - opex;
    const partnerLabel = activeAgreement.partnerName ?? "Partner";
    const partnerPctLabel = `${Math.round(activeAgreement.partner * 100)}%`;
    const boonzPctLabel = `${Math.round(activeAgreement.boonz * 100)}%`;

    let scenarioSteps: WaterfallStep[];
    if (commercialScenario === "VOX") {
      scenarioSteps = [
        { label: "Gross Revenue", value: scenarioGross, type: "total" },
        { label: "Returns/Refunds", value: -refunds, type: "subtract" },
        { label: "Net Revenue", value: scenarioNet, type: "subtotal" },
        {
          label: `${partnerLabel} Share (${partnerPctLabel})`,
          value: -voxShare,
          type: "subtract",
        },
        {
          label: `Boonz Net Revenue (${boonzPctLabel})`,
          value: voxBoonzNet,
          type: "subtotal",
        },
        { label: "Boonz COGS", value: -totalCogs, type: "subtract" },
        { label: "Gross Profit", value: voxGrossProfit, type: "subtotal" },
        { label: "Opex", value: -opex, type: "subtract" },
        { label: "EBITDA", value: voxEbitda, type: "total" },
      ];
    } else if (commercialScenario === "GRIT_OMD") {
      scenarioSteps = [
        { label: "Gross Revenue", value: scenarioGross, type: "total" },
        { label: "Returns/Refunds", value: -refunds, type: "subtract" },
        { label: "Net Revenue", value: scenarioNet, type: "subtotal" },
        {
          label: `${partnerLabel} Share (${partnerPctLabel})`,
          value: -gritPartner,
          type: "subtract",
        },
        {
          label: `Boonz Net Revenue (${boonzPctLabel})`,
          value: gritBoonzNet,
          type: "subtotal",
        },
        { label: "Opex", value: -opex, type: "subtract" },
        { label: "EBITDA", value: gritEbitda, type: "total" },
      ];
    } else {
      scenarioSteps = [
        { label: "Gross Revenue", value: scenarioGross, type: "total" },
        { label: "Returns/Refunds", value: -refunds, type: "subtract" },
        { label: "Net Revenue", value: scenarioNet, type: "total" },
      ];
    }

    const waterfallData: WaterfallBar[] = buildWaterfallBars(scenarioSteps);

    const ebitda = boonzRevenue - boonzCogs - opex;

    // group breakdown — uses unified per-group formula (gross − refunds − fees)
    const groupBreakdown = groupData.map((g) => {
      const gAdyen = settledAdyen.filter((a) => {
        const m = machineList.find((mm) => mm.machine_id === a.machine_id);
        return m?.venue_group === g.name;
      });
      const gCaptured = gAdyen.reduce(
        (s, r) => s + (r.captured_amount_value || 0),
        0,
      );
      const gFees = gCaptured * ADYEN_FEE_PCT;
      const gRefunds = adyenRows
        .filter((rw) => rw.status === "RefundedBulk")
        .filter((rw) => {
          const m = machineList.find((mm) => mm.machine_id === rw.machine_id);
          return m?.venue_group === g.name;
        })
        .reduce((s, rw) => s + (rw.captured_amount_value || 0), 0);
      const gNet = g.revenue - gRefunds - gFees;
      // B3: each group's boonz/partner split comes from its DB agreement.
      const gAgreement = agreementByGroup[g.name] ?? DEFAULT_AGREEMENT;
      const gBoonz = gNet * gAgreement.boonz;
      const gDues = gNet * gAgreement.partner - g.cogs;
      return {
        ...g,
        captured: gCaptured,
        netRevenue: gNet,
        boonzShare: gBoonz,
        netDues: gDues,
      };
    });

    return {
      netRevenue,
      adyenFees,
      refunds,
      boonzRevenue,
      partnerRevenue,
      boonzCogs,
      ebitda,
      waterfallData,
      groupBreakdown,
      // scenario-specific summary values
      scenario: commercialScenario,
      agreement: activeAgreement,
      scenarioGross,
      scenarioNet,
      opex,
      voxShare,
      voxBoonzNet,
      voxGrossProfit,
      voxEbitda,
      gritPartner,
      gritBoonzNet,
      gritEbitda,
    };
  }, [
    totalWeimi,
    capturedAdyen,
    gap,
    totalCogs,
    adyenRows,
    settledAdyen,
    groupData,
    machineList,
    commercialScenario,
    activeAgreement,
    agreementByGroup,
  ]);

  // unique machines with data
  const activeMachineCount = useMemo(
    () => new Set(salesRows.map((r) => r.machine_id)).size,
    [salesRows],
  );

  // ── scatter data for products ──
  const scatterData = useMemo(() => {
    return productData.slice(0, 30).map((p) => ({
      x: p.units,
      y: p.avgPrice,
      z: p.revenue,
      name: p.name,
    }));
  }, [productData]);

  // ── render helpers ──
  const statusColor = (s: string) => {
    if (s === "SettledBulk")
      return { bg: "rgba(36,84,74,0.12)", color: "#24544a" };
    if (s === "Cancelled" || s === "Refused")
      return { bg: "rgba(220,38,38,0.12)", color: "#dc2626" };
    if (s === "RefundedBulk")
      return { bg: "rgba(217,119,6,0.12)", color: "#d97706" };
    return { bg: "rgba(107,104,96,0.12)", color: "#6b6860" };
  };

  // ── RENDER ──
  return (
    <div
      style={{
        background: "#faf9f7",
        color: "#0a0a0a",
        fontFamily: font,
        fontSize: 13,
        lineHeight: 1.5,
        minHeight: "100vh",
      }}
    >
      {/* ── TAB NAV ── */}
      <nav
        style={{
          position: "sticky",
          top: 0,
          zIndex: 100,
          background: "rgba(250,249,247,0.97)",
          backdropFilter: "blur(12px)",
          borderBottom: "1px solid #e8e4de",
          display: "flex",
          alignItems: "center",
          padding: "0 24px",
          flexWrap: "wrap",
          fontFamily: font,
        }}
      >
        <div
          style={{
            fontWeight: 800,
            fontSize: 15,
            padding: "14px 24px 14px 0",
            borderRight: "1px solid #e8e4de",
            marginRight: 8,
            letterSpacing: "-0.5px",
          }}
        >
          Performance
        </div>
        {TABS.map((t) => (
          <button
            key={t}
            onClick={() => setActiveTab(t)}
            style={{
              padding: "12px 16px",
              fontSize: 12,
              fontWeight: activeTab === t ? 700 : 500,
              letterSpacing: "0.06em",
              textTransform: "uppercase",
              color: activeTab === t ? "#0a0a0a" : "#6b6860",
              borderBottom:
                activeTab === t ? "3px solid #0a0a0a" : "3px solid transparent",
              background: "none",
              border: "none",
              cursor: "pointer",
              whiteSpace: "nowrap",
              fontFamily: font,
              transition: "all 0.2s",
            }}
          >
            {t}
          </button>
        ))}
        <div
          style={{
            marginLeft: "auto",
            fontSize: 10,
            color: "#6b6860",
            display: "flex",
            gap: 16,
            alignItems: "center",
          }}
        >
          {lastUpdated && <span>Updated {lastUpdated}</span>}
        </div>
      </nav>

      {/* ── FILTER BAR ── */}
      <div
        style={{
          background: "#f5f2ee",
          borderBottom: "1px solid #e8e4de",
          padding: "10px 24px",
          display: "flex",
          alignItems: "center",
          gap: 14,
          flexWrap: "wrap",
          fontFamily: font,
        }}
      >
        <span style={cblStyle}>Period</span>
        <input
          type="date"
          value={dateFrom}
          onChange={(e) => setDateFrom(e.target.value)}
          style={dateStyle}
        />
        <span style={{ color: "#6b6860", fontSize: 11 }}>to</span>
        <input
          type="date"
          value={dateTo}
          onChange={(e) => setDateTo(e.target.value)}
          style={dateStyle}
        />
        <div
          style={{
            width: 1,
            height: 20,
            background: "#e8e4de",
            margin: "0 4px",
          }}
        />
        <span style={cblStyle}>Group</span>
        {GROUPS.map((g) => (
          <button
            key={g}
            onClick={() => setGroup(g)}
            style={{
              padding: "5px 14px",
              borderRadius: 4,
              fontSize: 11,
              cursor: "pointer",
              border: `1px solid ${group === g ? "#24544a" : "#e8e4de"}`,
              background: group === g ? "rgba(36,84,74,0.12)" : "#ffffff",
              color: group === g ? "#24544a" : "#6b6860",
              fontFamily: font,
            }}
          >
            {group === g ? "\u2713 " : ""}
            {g}
          </button>
        ))}
        <div
          style={{
            width: 1,
            height: 20,
            background: "#e8e4de",
            margin: "0 4px",
          }}
        />
        <span style={cblStyle}>Machines</span>
        <div
          ref={machineDropdownRef}
          style={{ position: "relative", fontFamily: font }}
        >
          <button
            onClick={() => setMachineDropdownOpen((o) => !o)}
            style={{
              padding: "5px 12px",
              borderRadius: 4,
              fontSize: 11,
              cursor: "pointer",
              border: `1px solid ${selectedMachineIds.length > 0 ? "#0E3F4D" : "#e8e4de"}`,
              background:
                selectedMachineIds.length > 0
                  ? "rgba(14,63,77,0.12)"
                  : "#ffffff",
              color: selectedMachineIds.length > 0 ? "#0E3F4D" : "#6b6860",
              fontFamily: font,
              display: "flex",
              alignItems: "center",
              gap: 6,
              minWidth: 110,
            }}
          >
            <span>
              {selectedMachineIds.length === 0
                ? "All"
                : `${selectedMachineIds.length} machine${selectedMachineIds.length === 1 ? "" : "s"}`}
            </span>
            <span style={{ fontSize: 9, opacity: 0.6 }}>
              {machineDropdownOpen ? "\u25B2" : "\u25BC"}
            </span>
          </button>
          {machineDropdownOpen && (
            <div
              style={{
                position: "absolute",
                top: "calc(100% + 4px)",
                left: 0,
                zIndex: 200,
                background: "#ffffff",
                border: "1px solid #e8e4de",
                borderRadius: 6,
                boxShadow: "0 6px 20px rgba(0,0,0,0.08)",
                width: 280,
                maxHeight: 360,
                display: "flex",
                flexDirection: "column",
                fontFamily: font,
              }}
            >
              <div
                style={{
                  padding: "8px 12px",
                  borderBottom: "1px solid #e8e4de",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "space-between",
                  fontSize: 10,
                  letterSpacing: "0.1em",
                  textTransform: "uppercase",
                  color: "#6b6860",
                }}
              >
                <span>
                  {selectedMachineIds.length === 0
                    ? "All machines"
                    : `${selectedMachineIds.length} selected`}
                </span>
                <button
                  onClick={() => setSelectedMachineIds([])}
                  disabled={selectedMachineIds.length === 0}
                  style={{
                    border: "none",
                    background: "none",
                    color:
                      selectedMachineIds.length === 0 ? "#c7c2bb" : "#dc2626",
                    fontSize: 10,
                    textTransform: "uppercase",
                    letterSpacing: "0.08em",
                    cursor:
                      selectedMachineIds.length === 0 ? "default" : "pointer",
                    fontFamily: font,
                  }}
                >
                  Clear
                </button>
              </div>
              <div
                style={{
                  flex: 1,
                  overflowY: "auto",
                  padding: "4px 0",
                }}
              >
                {dropdownMachines.length === 0 && (
                  <div
                    style={{
                      padding: "10px 12px",
                      fontSize: 11,
                      color: "#9a948e",
                    }}
                  >
                    No active machines
                  </div>
                )}
                {dropdownMachines.map((m) => {
                  const checked = selectedMachineIds.includes(m.machine_id);
                  return (
                    <label
                      key={m.machine_id}
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: 8,
                        padding: "6px 12px",
                        cursor: "pointer",
                        fontSize: 11.5,
                        color: "#0a0a0a",
                        background: checked
                          ? "rgba(14,63,77,0.06)"
                          : "transparent",
                      }}
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() => toggleMachineId(m.machine_id)}
                        style={{ cursor: "pointer" }}
                      />
                      <span
                        style={{
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                        }}
                      >
                        {m.official_name}
                      </span>
                    </label>
                  );
                })}
              </div>
            </div>
          )}
        </div>
        <div
          style={{
            width: 1,
            height: 20,
            background: "#e8e4de",
            margin: "0 4px",
          }}
        />
        <span style={cblStyle}>View</span>
        {(["consolidated", "by-group"] as const).map((v) => (
          <button
            key={v}
            onClick={() => {
              setViewMode(v);
              if (v === "consolidated") setTxnGroup("All");
            }}
            style={{
              padding: "5px 14px",
              borderRadius: 4,
              fontSize: 11,
              cursor: "pointer",
              border: `1px solid ${viewMode === v ? "#F59E0B" : "#e8e4de"}`,
              background: viewMode === v ? "rgba(245,158,11,0.12)" : "#ffffff",
              color: viewMode === v ? "#F59E0B" : "#6b6860",
              fontFamily: font,
            }}
          >
            {v === "consolidated" ? "Consolidated" : "By Group"}
          </button>
        ))}
        <div
          style={{
            width: 1,
            height: 20,
            background: "#e8e4de",
            margin: "0 4px",
          }}
        />
        <button
          onClick={handleRefresh}
          disabled={loading}
          style={{
            padding: "5px 12px",
            borderRadius: 4,
            fontSize: 11,
            cursor: loading ? "default" : "pointer",
            border: "1px solid #e8e4de",
            background: "#ffffff",
            color: "#6b6860",
            display: "flex",
            alignItems: "center",
            gap: 6,
            fontFamily: font,
          }}
        >
          <span style={{ fontSize: 14, lineHeight: 1 }}>
            {loading ? "\u23F3" : "\u21BB"}
          </span>{" "}
          Refresh
        </button>
        {lastUpdated && (
          <span style={{ fontSize: 10, color: "#6b6860" }}>
            Last: {lastUpdated}
          </span>
        )}
        {loading && (
          <span style={{ fontSize: 10, color: "#F59E0B", marginLeft: "auto" }}>
            Loading...
          </span>
        )}
      </div>

      {/* ── PAYMENT DEFAULT STRIP ── */}
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
          fontFamily: font,
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
          <strong style={{ color: "#ffffff" }}>AED {fmtN(totalWeimi)}</strong>
        </span>
        <span style={{ color: "rgba(255,255,255,0.3)" }}>|</span>
        <span style={{ color: "rgba(255,255,255,0.8)" }}>
          Captured{" "}
          <strong style={{ color: "#a7f3d0" }}>
            AED {fmtN(capturedAdyen)}
          </strong>
        </span>
        <span style={{ color: "rgba(255,255,255,0.3)" }}>|</span>
        <span style={{ color: "rgba(255,255,255,0.8)" }}>
          Gap{" "}
          <strong style={{ color: "#fca5a5" }}>
            AED {fmtN(Math.abs(gap))}
          </strong>
        </span>
        <span style={{ color: "rgba(255,255,255,0.3)" }}>|</span>
        <span style={{ color: "rgba(255,255,255,0.8)" }}>
          Default{" "}
          <strong style={{ color: "#fde68a", fontSize: 14 }}>
            {defaultPct.toFixed(2)}%
          </strong>
        </span>
        <span style={{ color: "rgba(255,255,255,0.3)" }}>|</span>
        <span style={{ color: "rgba(255,255,255,0.6)", fontSize: 10 }}>
          {matchedCount}/{totalCount} matched
        </span>
      </div>

      {/* ── TAB CONTENT ── */}
      <div style={{ padding: "28px 24px", maxWidth: 1400, margin: "0 auto" }}>
        {/* ── OVERVIEW ── */}
        {activeTab === "Overview" && (
          <div>
            <SectionLabel
              text={`${dateFrom} to ${dateTo} \u00B7 ${group === "All" ? "All Groups" : group}`}
            />
            <h2
              style={{
                fontFamily: font,
                fontWeight: 700,
                fontSize: 22,
                letterSpacing: "-0.5px",
                marginBottom: 4,
              }}
            >
              Performance Dashboard — Executive Report
            </h2>
            <p style={{ fontSize: 11, color: "#6b6860", marginBottom: 20 }}>
              {fmtN(totalCount)} transactions across {activeMachineCount}{" "}
              machines
            </p>

            {/* stat cards */}
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "1fr 1fr 1fr",
                gap: 14,
                marginBottom: 28,
              }}
            >
              <StatCard
                label="Total Revenue"
                value={fmtAed(totalWeimi)}
                subtitle={`${fmtN(totalUnits)} units sold`}
                accent="#8B5CF6"
                valueColor="#8B5CF6"
              />
              <StatCard
                label="Active Machines"
                value={String(activeMachineCount)}
                subtitle={`across ${groupData.length} venue groups`}
                accent="#d97706"
                valueColor="#d97706"
              />
              <StatCard
                label="Payment Default"
                value={`${defaultPct.toFixed(2)}%`}
                subtitle={`Gap: ${fmtAed(Math.abs(gap))}`}
                accent="#dc2626"
                valueColor="#dc2626"
              />
            </div>

            {/* charts 2x2 */}
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "1fr 1fr",
                gap: 14,
                marginBottom: 28,
              }}
            >
              <div
                style={{
                  background: "white",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "18px 20px",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    marginBottom: 12,
                  }}
                >
                  Daily Revenue
                </h3>
                <ResponsiveContainer width="100%" height={220}>
                  <BarChart data={dailyData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" />
                    <XAxis
                      dataKey="date"
                      tick={{ fontSize: 10, fill: "#6b6860" }}
                    />
                    <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
                    <Tooltip
                      contentStyle={{
                        background: "#fff",
                        border: "1px solid #e8e4de",
                        borderRadius: 4,
                        fontSize: 11,
                      }}
                      // eslint-disable-next-line @typescript-eslint/no-explicit-any
                      formatter={(value: any) => [fmtAed(value), "Revenue"]}
                    />
                    <Bar
                      dataKey="amount"
                      fill="#24544a"
                      radius={[3, 3, 0, 0]}
                    />
                  </BarChart>
                </ResponsiveContainer>
              </div>
              <div
                style={{
                  background: "white",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "18px 20px",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    marginBottom: 12,
                  }}
                >
                  Week-on-Week
                </h3>
                <ResponsiveContainer width="100%" height={220}>
                  <BarChart data={weeklyData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" />
                    <XAxis
                      dataKey="week"
                      tick={{ fontSize: 10, fill: "#6b6860" }}
                    />
                    <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
                    <Tooltip
                      contentStyle={{
                        background: "#fff",
                        border: "1px solid #e8e4de",
                        borderRadius: 4,
                        fontSize: 11,
                      }}
                      // eslint-disable-next-line @typescript-eslint/no-explicit-any
                      formatter={(value: any) => [fmtAed(value), "Revenue"]}
                    />
                    <Bar
                      dataKey="amount"
                      fill="#e1b460"
                      radius={[3, 3, 0, 0]}
                    />
                  </BarChart>
                </ResponsiveContainer>
              </div>
              <div
                style={{
                  background: "white",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "18px 20px",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    marginBottom: 12,
                  }}
                >
                  Hourly Distribution
                </h3>
                <ResponsiveContainer width="100%" height={220}>
                  <BarChart data={hourlyData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" />
                    <XAxis
                      dataKey="hour"
                      tick={{ fontSize: 10, fill: "#6b6860" }}
                    />
                    <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
                    <Tooltip
                      contentStyle={{
                        background: "#fff",
                        border: "1px solid #e8e4de",
                        borderRadius: 4,
                        fontSize: 11,
                      }}
                      // eslint-disable-next-line @typescript-eslint/no-explicit-any
                      formatter={(value: any) => [fmtAed(value), "Revenue"]}
                    />
                    <Bar
                      dataKey="amount"
                      fill="#4a7a6d"
                      radius={[3, 3, 0, 0]}
                    />
                  </BarChart>
                </ResponsiveContainer>
              </div>
              <div
                style={{
                  background: "white",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "18px 20px",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    marginBottom: 12,
                  }}
                >
                  Day of Week
                </h3>
                <ResponsiveContainer width="100%" height={220}>
                  <BarChart data={dowData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" />
                    <XAxis
                      dataKey="day"
                      tick={{ fontSize: 10, fill: "#6b6860" }}
                    />
                    <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
                    <Tooltip
                      contentStyle={{
                        background: "#fff",
                        border: "1px solid #e8e4de",
                        borderRadius: 4,
                        fontSize: 11,
                      }}
                      // eslint-disable-next-line @typescript-eslint/no-explicit-any
                      formatter={(value: any) => [fmtAed(value), "Revenue"]}
                    />
                    <Bar
                      dataKey="amount"
                      fill="#2563eb"
                      radius={[3, 3, 0, 0]}
                    />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>

            {/* data coverage */}
            <div
              style={{
                background: "white",
                border: "1px solid #e8e4de",
                borderRadius: 6,
                padding: "18px 20px",
              }}
            >
              <h3
                style={{
                  fontFamily: font,
                  fontWeight: 600,
                  fontSize: 15,
                  marginBottom: 12,
                }}
              >
                Data Coverage
              </h3>
              <div style={{ display: "flex", gap: 32, fontSize: 12 }}>
                <div>
                  <span style={{ color: "#6b6860" }}>Weimi (Sales): </span>
                  <strong style={{ color: "#24544a" }}>Live</strong> —{" "}
                  {fmtN(totalCount)} rows
                </div>
                <div>
                  <span style={{ color: "#6b6860" }}>Adyen (Payments): </span>
                  <strong
                    style={{ color: totalCount > 0 ? "#24544a" : "#dc2626" }}
                  >
                    {pct(matchedCount, totalCount)} matched
                  </strong>{" "}
                  — {fmtN(adyenRows.length)} rows
                </div>
              </div>
            </div>

            {/* by-group breakdown (only in by-group view) */}
            {viewMode === "by-group" && groupData.length > 0 && (
              <div
                style={{
                  background: "white",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  overflow: "hidden",
                  marginTop: 14,
                }}
              >
                <div
                  style={{
                    padding: "14px 20px",
                    borderBottom: "1px solid #e8e4de",
                  }}
                >
                  <h3
                    style={{
                      fontFamily: font,
                      fontWeight: 600,
                      fontSize: 15,
                      margin: 0,
                    }}
                  >
                    Performance by Group
                  </h3>
                </div>
                <div style={{ overflowX: "auto" }}>
                  <table
                    style={{
                      width: "100%",
                      borderCollapse: "collapse",
                      fontSize: 11.5,
                      minWidth: 700,
                    }}
                  >
                    <thead>
                      <tr>
                        {[
                          "Group",
                          "Revenue",
                          "Transactions",
                          "Units",
                          "Avg/Txn",
                          "% Share",
                        ].map((h) => (
                          <th
                            key={h}
                            style={{
                              background: "#f5f2ee",
                              padding: "10px 12px",
                              textAlign: h === "Group" ? "left" : "right",
                              fontSize: 9.5,
                              letterSpacing: ".1em",
                              textTransform: "uppercase",
                              color: "#6b6860",
                              fontWeight: 500,
                              borderBottom: "1px solid #e8e4de",
                            }}
                          >
                            {h}
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {groupData.map((g) => (
                        <tr
                          key={g.name}
                          style={{ borderBottom: "1px solid #e8e4de" }}
                        >
                          <td style={{ padding: "9px 12px", fontWeight: 500 }}>
                            <span
                              style={{
                                fontSize: 10,
                                padding: "2px 8px",
                                borderRadius: 3,
                                background: `${GROUP_COLORS[g.name] || "#6b6860"}18`,
                                color: GROUP_COLORS[g.name] || "#6b6860",
                                fontWeight: 600,
                              }}
                            >
                              {g.name}
                            </span>
                          </td>
                          <td
                            style={{
                              padding: "9px 12px",
                              textAlign: "right",
                              fontWeight: 500,
                            }}
                          >
                            {fmtAed(g.revenue)}
                          </td>
                          <td
                            style={{ padding: "9px 12px", textAlign: "right" }}
                          >
                            {fmtN(g.txns)}
                          </td>
                          <td
                            style={{ padding: "9px 12px", textAlign: "right" }}
                          >
                            {fmtN(g.units)}
                          </td>
                          <td
                            style={{ padding: "9px 12px", textAlign: "right" }}
                          >
                            {fmtAed(g.txns > 0 ? g.revenue / g.txns : 0)}
                          </td>
                          <td
                            style={{ padding: "9px 12px", textAlign: "right" }}
                          >
                            {pct(g.revenue, totalWeimi)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
          </div>
        )}

        {/* ── SITES & MACHINES ── */}
        {activeTab === "Sites & Machines" && (
          <div>
            <SectionLabel
              text={`${dateFrom} to ${dateTo} \u00B7 VENUE GROUP PERFORMANCE`}
            />
            <h2
              style={{
                fontFamily: font,
                fontWeight: 700,
                fontSize: 22,
                letterSpacing: "-0.5px",
                marginBottom: 20,
              }}
            >
              Sites &amp; Machine Performance
            </h2>

            {groupData.map((g) => {
              const dailyTrend = groupDailyTrends[g.name] || [];
              const groupMachines = machineData.filter(
                (m) => m.group === g.name,
              );
              const topMachineRev = groupMachines[0]?.revenue || 1;

              return (
                <div key={g.name} style={{ marginBottom: 28 }}>
                  {/* group header */}
                  <div
                    style={{
                      background: "white",
                      border: "1px solid #e8e4de",
                      borderRadius: 6,
                      padding: "18px 20px",
                      marginBottom: 14,
                      position: "relative",
                      overflow: "hidden",
                    }}
                  >
                    <div
                      style={{
                        position: "absolute",
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 2,
                        background: GROUP_COLORS[g.name] || "#6b6860",
                      }}
                    />
                    <div
                      style={{
                        display: "flex",
                        justifyContent: "space-between",
                        alignItems: "center",
                        flexWrap: "wrap",
                        gap: 12,
                      }}
                    >
                      <div>
                        <div
                          style={{
                            fontFamily: font,
                            fontWeight: 700,
                            fontSize: 16,
                            marginBottom: 4,
                          }}
                        >
                          {g.name}
                        </div>
                        <div style={{ fontSize: 11, color: "#6b6860" }}>
                          {g.machineCount} machines &middot; {fmtN(g.txns)} txns
                          &middot; {fmtN(g.units)} units
                        </div>
                      </div>
                      <div style={{ textAlign: "right" }}>
                        <div
                          style={{
                            fontSize: 22,
                            fontWeight: 800,
                            letterSpacing: "-1px",
                            color: GROUP_COLORS[g.name] || "#0a0a0a",
                            fontFamily: font,
                          }}
                        >
                          {fmtAed(g.revenue)}
                        </div>
                        <div style={{ fontSize: 10, color: "#6b6860" }}>
                          {pct(g.revenue, totalWeimi)} of total
                        </div>
                      </div>
                    </div>

                    {/* daily trend */}
                    {dailyTrend.length > 1 && (
                      <div style={{ marginTop: 12 }}>
                        <ResponsiveContainer width="100%" height={120}>
                          <LineChart data={dailyTrend}>
                            <XAxis
                              dataKey="date"
                              tick={{ fontSize: 9, fill: "#9a948e" }}
                              tickFormatter={(d) => d.slice(5)}
                            />
                            <YAxis
                              tick={{ fontSize: 9, fill: "#9a948e" }}
                              width={50}
                            />
                            <Tooltip
                              contentStyle={{
                                background: "#fff",
                                border: "1px solid #e8e4de",
                                borderRadius: 4,
                                fontSize: 11,
                              }}
                              // eslint-disable-next-line @typescript-eslint/no-explicit-any
                              formatter={(value: any) => [
                                fmtAed(value),
                                "Revenue",
                              ]}
                            />
                            <Line
                              type="monotone"
                              dataKey="amount"
                              stroke="#24544a"
                              strokeWidth={2}
                              dot={false}
                            />
                          </LineChart>
                        </ResponsiveContainer>
                      </div>
                    )}
                  </div>

                  {/* machine breakdown */}
                  <div
                    style={{
                      background: "white",
                      border: "1px solid #e8e4de",
                      borderRadius: 6,
                      padding: "18px 20px",
                    }}
                  >
                    <h3
                      style={{
                        fontFamily: font,
                        fontWeight: 600,
                        fontSize: 13,
                        marginBottom: 12,
                        color: "#6b6860",
                      }}
                    >
                      Machine Breakdown
                    </h3>
                    {groupMachines.map((m) => (
                      <ProgressRow
                        key={m.id}
                        label={m.name}
                        value={m.revenue}
                        max={topMachineRev}
                        color={GROUP_COLORS[g.name] || "#24544a"}
                        display={fmtAed(m.revenue)}
                      />
                    ))}
                    {groupMachines.length === 0 && (
                      <div style={{ fontSize: 11, color: "#9a948e" }}>
                        No machine data
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* ── PRODUCTS ── */}
        {activeTab === "Products" && (
          <div>
            <SectionLabel
              text={`${dateFrom} to ${dateTo} \u00B7 PRODUCT ANALYTICS`}
            />
            <h2
              style={{
                fontFamily: font,
                fontWeight: 700,
                fontSize: 22,
                letterSpacing: "-0.5px",
                marginBottom: 20,
              }}
            >
              Product Performance
            </h2>

            {/* Volume vs Value + Revenue by Product side-by-side */}
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(2, minmax(0, 1fr))",
                gap: 14,
                marginBottom: 14,
              }}
            >
              {/* scatter chart */}
              <div
                style={{
                  background: "white",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "18px 20px",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    marginBottom: 12,
                  }}
                >
                  Volume vs Value
                </h3>
                <ResponsiveContainer width="100%" height={300}>
                  <ScatterChart>
                    <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" />
                    <XAxis
                      type="number"
                      dataKey="x"
                      name="Units"
                      tick={{ fontSize: 10, fill: "#6b6860" }}
                      label={{
                        value: "Units Sold",
                        position: "insideBottom",
                        offset: -5,
                        style: { fontSize: 10, fill: "#6b6860" },
                      }}
                    />
                    <YAxis
                      type="number"
                      dataKey="y"
                      name="Avg Price"
                      tick={{ fontSize: 10, fill: "#6b6860" }}
                      label={{
                        value: "Avg Price (AED)",
                        angle: -90,
                        position: "insideLeft",
                        style: { fontSize: 10, fill: "#6b6860" },
                      }}
                    />
                    <ZAxis
                      type="number"
                      dataKey="z"
                      range={[60, 600]}
                      name="Revenue"
                    />
                    <Tooltip
                      contentStyle={{
                        background: "#fff",
                        border: "1px solid #e8e4de",
                        borderRadius: 4,
                        fontSize: 11,
                      }}
                      // eslint-disable-next-line @typescript-eslint/no-explicit-any
                      formatter={(value: any, name: any) => [
                        name === "Revenue"
                          ? fmtAed(value)
                          : name === "Avg Price"
                            ? `AED ${Number(value).toFixed(2)}`
                            : fmtN(value),
                        name,
                      ]}
                    />
                    <Scatter data={scatterData} fill="#24544a">
                      {scatterData.map((_, i) => (
                        <Cell
                          key={i}
                          fill={
                            Object.values(GROUP_COLORS)[
                              i % Object.values(GROUP_COLORS).length
                            ]
                          }
                        />
                      ))}
                    </Scatter>
                  </ScatterChart>
                </ResponsiveContainer>
              </div>

              {/* horizontal bar chart - top 15 */}
              <div
                style={{
                  background: "white",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  padding: "18px 20px",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    marginBottom: 12,
                  }}
                >
                  Revenue by Product (Top 15)
                </h3>
                <ResponsiveContainer
                  width="100%"
                  height={Math.max(300, productData.slice(0, 15).length * 32)}
                >
                  <BarChart
                    data={productData.slice(0, 15).map((p) => ({
                      ...p,
                      name:
                        p.name.length > 30
                          ? p.name.slice(0, 27) + "..."
                          : p.name,
                      revenue: Math.round(p.revenue),
                    }))}
                    layout="vertical"
                  >
                    <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" />
                    <XAxis
                      type="number"
                      tick={{ fontSize: 10, fill: "#6b6860" }}
                    />
                    <YAxis
                      type="category"
                      dataKey="name"
                      width={180}
                      tick={{ fontSize: 10, fill: "#6b6860" }}
                    />
                    <Tooltip
                      contentStyle={{
                        background: "#fff",
                        border: "1px solid #e8e4de",
                        borderRadius: 4,
                        fontSize: 11,
                      }}
                      // eslint-disable-next-line @typescript-eslint/no-explicit-any
                      formatter={(value: any) => [fmtAed(value), "Revenue"]}
                    />
                    <Bar
                      dataKey="revenue"
                      fill="#24544a"
                      radius={[0, 3, 3, 0]}
                    />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>

            {/* product detail table */}
            <div
              style={{
                background: "white",
                border: "1px solid #e8e4de",
                borderRadius: 6,
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  padding: "14px 20px",
                  borderBottom: "1px solid #e8e4de",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    margin: 0,
                  }}
                >
                  Product Detail
                </h3>
              </div>
              <div style={{ overflowX: "auto" }}>
                <table
                  style={{
                    width: "100%",
                    borderCollapse: "collapse",
                    fontSize: 11.5,
                    minWidth: 800,
                  }}
                >
                  <thead>
                    <tr>
                      {(viewMode === "by-group"
                        ? [
                            "Product",
                            "Groups",
                            "Revenue",
                            "Units",
                            "Avg Price",
                            "Share",
                          ]
                        : ["Product", "Revenue", "Units", "Avg Price", "Share"]
                      ).map((h) => (
                        <th
                          key={h}
                          style={{
                            background: "#f5f2ee",
                            padding: "10px 12px",
                            textAlign:
                              h === "Product" || h === "Groups"
                                ? "left"
                                : "right",
                            fontSize: 9.5,
                            letterSpacing: ".1em",
                            textTransform: "uppercase",
                            color: "#6b6860",
                            fontWeight: 500,
                            whiteSpace: "nowrap",
                            borderBottom: "1px solid #e8e4de",
                          }}
                        >
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {productData.map((p) => (
                      <tr
                        key={p.name}
                        style={{ borderBottom: "1px solid #e8e4de" }}
                      >
                        <td
                          style={{
                            padding: "9px 12px",
                            fontWeight: 500,
                            maxWidth: 220,
                            overflow: "hidden",
                            textOverflow: "ellipsis",
                            whiteSpace: "nowrap",
                          }}
                        >
                          {p.name}
                        </td>
                        {viewMode === "by-group" && (
                          <td style={{ padding: "9px 12px" }}>
                            <div
                              style={{
                                display: "flex",
                                gap: 4,
                                flexWrap: "wrap",
                              }}
                            >
                              {p.groups.map((g) => (
                                <span
                                  key={g}
                                  style={{
                                    fontSize: 9,
                                    padding: "2px 6px",
                                    borderRadius: 3,
                                    background: `${GROUP_COLORS[g] || "#6b6860"}18`,
                                    color: GROUP_COLORS[g] || "#6b6860",
                                    fontWeight: 500,
                                  }}
                                >
                                  {g}
                                </span>
                              ))}
                            </div>
                          </td>
                        )}
                        <td
                          style={{
                            padding: "9px 12px",
                            textAlign: "right",
                            fontWeight: 500,
                          }}
                        >
                          {fmtAed(p.revenue)}
                        </td>
                        <td style={{ padding: "9px 12px", textAlign: "right" }}>
                          {fmtN(p.units)}
                        </td>
                        <td style={{ padding: "9px 12px", textAlign: "right" }}>
                          {fmtAed(p.avgPrice)}
                        </td>
                        <td style={{ padding: "9px 12px", textAlign: "right" }}>
                          {pct(p.revenue, totalWeimi)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        )}

        {/* ── PAYMENTS ── */}
        {activeTab === "Payments" && (
          <div>
            <SectionLabel
              text={`${dateFrom} to ${dateTo} \u00B7 PAYMENT ANALYTICS`}
            />
            <h2
              style={{
                fontFamily: font,
                fontWeight: 700,
                fontSize: 22,
                letterSpacing: "-0.5px",
                marginBottom: 20,
              }}
            >
              Payment Breakdown
            </h2>

            {/* stat cards */}
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "1fr 1fr 1fr",
                gap: 14,
                marginBottom: 28,
              }}
            >
              <StatCard
                label="Total Captured"
                value={fmtAed(paymentStats.totalCaptured)}
                subtitle={`from ${fmtN(adyenRows.length)} Adyen transactions`}
                accent="#24544a"
                valueColor="#24544a"
              />
              <StatCard
                label="Settled Transactions"
                value={fmtN(paymentStats.totalTxns)}
                subtitle={`${pct(paymentStats.totalTxns, adyenRows.length)} of all Adyen txns`}
                accent="#e1b460"
                valueColor="#d97706"
              />
              <StatCard
                label="Avg Transaction"
                value={fmtAed(paymentStats.avgTxn)}
                subtitle="per settled transaction"
                accent="#8B5CF6"
                valueColor="#8B5CF6"
              />
            </div>

            {/* pie charts — Funding Source & Payment Method */}
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(2, minmax(0, 1fr))",
                gap: 14,
                marginBottom: 14,
              }}
            >
              {(
                [
                  {
                    title: "Funding Source",
                    data: paymentStats.funding,
                    palette: [
                      "#24544a",
                      "#0F4D3A",
                      "#6366F1",
                      "#8B5CF6",
                      "#6b6860",
                    ],
                  },
                  {
                    title: "Payment Method",
                    data: paymentStats.methods,
                    palette: [
                      "#e1b460",
                      "#d97706",
                      "#2A3547",
                      "#F59E0B",
                      "#9a948e",
                    ],
                  },
                ] as const
              ).map((p) => (
                <div
                  key={p.title}
                  style={{
                    background: "white",
                    border: "1px solid #e8e4de",
                    borderRadius: 6,
                    padding: "18px 20px",
                  }}
                >
                  <h3
                    style={{
                      fontFamily: font,
                      fontWeight: 600,
                      fontSize: 15,
                      marginBottom: 14,
                    }}
                  >
                    {p.title}
                  </h3>
                  {p.data.length === 0 ? (
                    <p style={{ fontSize: 11, color: "#6b6860" }}>
                      No data for this period.
                    </p>
                  ) : (
                    <ResponsiveContainer width="100%" height={220}>
                      <PieChart>
                        <Pie
                          data={p.data.map((d) => ({
                            name: d.name,
                            value: Math.round(d.amount),
                          }))}
                          dataKey="value"
                          nameKey="name"
                          cx="50%"
                          cy="50%"
                          outerRadius={80}
                          innerRadius={42}
                          paddingAngle={2}
                        >
                          {p.data.map((_, i) => (
                            <Cell
                              key={i}
                              fill={p.palette[i % p.palette.length]}
                            />
                          ))}
                        </Pie>
                        <Tooltip
                          contentStyle={{
                            background: "#fff",
                            border: "1px solid #e8e4de",
                            borderRadius: 4,
                            fontSize: 11,
                          }}
                          // eslint-disable-next-line @typescript-eslint/no-explicit-any
                          formatter={(v: any) => [fmtAed(v), "Captured"]}
                        />
                        <Legend
                          wrapperStyle={{ fontSize: 11, color: "#6b6860" }}
                        />
                      </PieChart>
                    </ResponsiveContainer>
                  )}
                </div>
              ))}
            </div>

            {/* funding source */}
            <div
              style={{
                background: "white",
                border: "1px solid #e8e4de",
                borderRadius: 6,
                padding: "18px 20px",
                marginBottom: 14,
              }}
            >
              <h3
                style={{
                  fontFamily: font,
                  fontWeight: 600,
                  fontSize: 15,
                  marginBottom: 14,
                }}
              >
                Funding Source
              </h3>
              {paymentStats.funding.map((f) => (
                <ProgressRow
                  key={f.name}
                  label={f.name}
                  value={f.amount}
                  max={paymentStats.funding[0]?.amount || 1}
                  color="#24544a"
                  display={fmtAed(f.amount)}
                />
              ))}
            </div>

            {/* payment method */}
            <div
              style={{
                background: "white",
                border: "1px solid #e8e4de",
                borderRadius: 6,
                padding: "18px 20px",
                marginBottom: 14,
              }}
            >
              <h3
                style={{
                  fontFamily: font,
                  fontWeight: 600,
                  fontSize: 15,
                  marginBottom: 14,
                }}
              >
                Payment Method
              </h3>
              {paymentStats.methods.map((m) => (
                <ProgressRow
                  key={m.name}
                  label={m.name}
                  value={m.amount}
                  max={paymentStats.methods[0]?.amount || 1}
                  color="#e1b460"
                  display={fmtAed(m.amount)}
                />
              ))}
            </div>

            {/* status breakdown */}
            <div
              style={{
                background: "white",
                border: "1px solid #e8e4de",
                borderRadius: 6,
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  padding: "14px 20px",
                  borderBottom: "1px solid #e8e4de",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    margin: 0,
                  }}
                >
                  Status Breakdown
                </h3>
              </div>
              <div style={{ overflowX: "auto" }}>
                <table
                  style={{
                    width: "100%",
                    borderCollapse: "collapse",
                    fontSize: 11.5,
                  }}
                >
                  <thead>
                    <tr>
                      {["Status", "Count", "Share"].map((h) => (
                        <th
                          key={h}
                          style={{
                            background: "#f5f2ee",
                            padding: "10px 12px",
                            textAlign: h === "Status" ? "left" : "right",
                            fontSize: 9.5,
                            letterSpacing: ".1em",
                            textTransform: "uppercase",
                            color: "#6b6860",
                            fontWeight: 500,
                            borderBottom: "1px solid #e8e4de",
                          }}
                        >
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {paymentStats.statuses.map((s) => {
                      const sc = statusColor(s.name);
                      return (
                        <tr
                          key={s.name}
                          style={{ borderBottom: "1px solid #e8e4de" }}
                        >
                          <td style={{ padding: "9px 12px" }}>
                            <span
                              style={{
                                fontSize: 10,
                                padding: "2px 8px",
                                borderRadius: 3,
                                background: sc.bg,
                                color: sc.color,
                                fontWeight: 600,
                                display: "inline-block",
                              }}
                            >
                              {s.name}
                            </span>
                          </td>
                          <td
                            style={{
                              padding: "9px 12px",
                              textAlign: "right",
                              fontWeight: 500,
                            }}
                          >
                            {fmtN(s.count)}
                          </td>
                          <td
                            style={{ padding: "9px 12px", textAlign: "right" }}
                          >
                            {pct(s.count, adyenRows.length)}
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

        {/* ── TRANSACTIONS ── */}
        {activeTab === "Transactions" && (
          <div>
            <SectionLabel
              text={`${dateFrom} to ${dateTo} \u00B7 TRANSACTION LEDGER`}
            />
            <h2
              style={{
                fontFamily: font,
                fontWeight: 700,
                fontSize: 22,
                letterSpacing: "-0.5px",
                marginBottom: 4,
              }}
            >
              Transaction Detail
            </h2>
            <p style={{ fontSize: 11, color: "#6b6860", marginBottom: 16 }}>
              {fmtN(filteredTxns.length)} transactions
            </p>

            {/* PAYMENT DEFAULT banner */}
            <div
              style={{
                background: "#2A3547",
                color: "#fff",
                borderRadius: 6,
                padding: "12px 18px",
                marginBottom: 14,
                display: "flex",
                alignItems: "center",
                flexWrap: "wrap",
                gap: 18,
                fontFamily: font,
                fontSize: 11.5,
              }}
            >
              <span
                style={{
                  fontSize: 10,
                  letterSpacing: ".15em",
                  fontWeight: 700,
                  color: "#e1b460",
                }}
              >
                PAYMENT DEFAULT
              </span>
              <span>Total {fmtAed(totalWeimi)}</span>
              <span style={{ color: "#cbd5e1" }}>|</span>
              <span>Captured {fmtAed(capturedAdyen)}</span>
              <span style={{ color: "#cbd5e1" }}>|</span>
              <span style={{ color: gap > 0 ? "#fca5a5" : "#86efac" }}>
                Gap {fmtAed(gap)}
              </span>
              <span style={{ color: "#cbd5e1" }}>|</span>
              <span>Default {defaultPct.toFixed(2)}%</span>
              <span style={{ color: "#cbd5e1" }}>|</span>
              <span
                style={{ color: defaultTxnCount > 0 ? "#fca5a5" : undefined }}
              >
                {fmtN(defaultTxnCount)} default
                {defaultTxnCount === 1 ? "" : "s"}
              </span>
              <span style={{ color: "#cbd5e1" }}>|</span>
              <span>
                {fmtN(matchedCount)}/{fmtN(totalCount)} matched
              </span>
            </div>

            {/* sub-filters */}
            <div
              style={{
                display: "flex",
                gap: 10,
                alignItems: "center",
                flexWrap: "wrap",
                marginBottom: 14,
              }}
            >
              {viewMode === "by-group" && (
                <>
                  {GROUPS.map((g) => (
                    <button
                      key={g}
                      onClick={() => {
                        setTxnGroup(g);
                        setTxnPage(0);
                      }}
                      style={{
                        padding: "6px 14px",
                        borderRadius: 4,
                        border: `1px solid ${txnGroup === g ? "#24544a" : "#e8e4de"}`,
                        background:
                          txnGroup === g ? "rgba(36,84,74,0.12)" : "#ffffff",
                        color: txnGroup === g ? "#24544a" : "#9a948e",
                        fontSize: 11,
                        fontFamily: font,
                        cursor: "pointer",
                        transition: "all .15s",
                      }}
                    >
                      {g}
                    </button>
                  ))}
                  <div
                    style={{
                      width: 1,
                      height: 20,
                      background: "#e8e4de",
                      margin: "0 4px",
                    }}
                  />
                </>
              )}
              {["All", "DEBIT", "CREDIT", "PREPAID"].map((f) => (
                <button
                  key={f}
                  onClick={() => {
                    setTxnFunding(f);
                    setTxnPage(0);
                  }}
                  style={{
                    padding: "6px 14px",
                    borderRadius: 4,
                    border: `1px solid ${txnFunding === f ? "#e1b460" : "#e8e4de"}`,
                    background:
                      txnFunding === f ? "rgba(225,180,96,0.12)" : "#ffffff",
                    color: txnFunding === f ? "#b45309" : "#9a948e",
                    fontSize: 11,
                    fontFamily: font,
                    cursor: "pointer",
                    transition: "all .15s",
                  }}
                >
                  {f === "All" ? "All Funding" : f}
                </button>
              ))}
              {/* B3 Fix 4: DEFAULT toggle — mutually exclusive with the
                  DEBIT/CREDIT/PREPAID buttons above. Amber styling to
                  visually distinguish this as a quality/status filter
                  rather than a funding-type filter. */}
              <button
                onClick={() => {
                  setTxnFunding(txnFunding === "DEFAULT" ? "All" : "DEFAULT");
                  setTxnPage(0);
                }}
                style={{
                  padding: "6px 14px",
                  borderRadius: 4,
                  border: `1px solid ${txnFunding === "DEFAULT" ? "#d97706" : "#f59e0b"}`,
                  background:
                    txnFunding === "DEFAULT"
                      ? "rgba(245,158,11,0.25)"
                      : "rgba(245,158,11,0.06)",
                  color: txnFunding === "DEFAULT" ? "#92400e" : "#d97706",
                  fontSize: 11,
                  fontFamily: font,
                  fontWeight: 600,
                  cursor: "pointer",
                  transition: "all .15s",
                }}
                title="Rows with no settled Adyen match (pending / refused / refunded)"
              >
                DEFAULT ({fmtN(defaultTxnCount)})
              </button>
              <div style={{ flex: 1 }} />
              <input
                type="text"
                placeholder="Search machine, product..."
                value={txnSearch}
                onChange={(e) => {
                  setTxnSearch(e.target.value);
                  setTxnPage(0);
                }}
                style={{
                  padding: "6px 12px",
                  borderRadius: 4,
                  border: "1px solid #e8e4de",
                  background: "#ffffff",
                  color: "#0a0a0a",
                  fontSize: 11,
                  fontFamily: font,
                  outline: "none",
                  width: 220,
                }}
              />
            </div>

            {/* table */}
            <div
              style={{
                overflowX: "auto",
                borderRadius: 6,
                border: "1px solid #e8e4de",
              }}
            >
              <table
                style={{
                  width: "100%",
                  borderCollapse: "collapse",
                  fontSize: 11.5,
                  minWidth: 1200,
                }}
              >
                <thead>
                  <tr>
                    {[
                      "Date",
                      "Time",
                      "Machine",
                      "Site",
                      "PSP",
                      "Fund",
                      "Card",
                      "Wallet",
                      "Total",
                      "Captured",
                      "Qty",
                      "Items",
                    ].map((h) => (
                      <th
                        key={h}
                        style={{
                          background: "#f5f2ee",
                          padding: "10px 12px",
                          textAlign: [
                            "Qty",
                            "Total",
                            "Captured",
                            "Wallet",
                          ].includes(h)
                            ? "right"
                            : "left",
                          fontSize: 9.5,
                          letterSpacing: ".1em",
                          textTransform: "uppercase",
                          color: "#6b6860",
                          fontWeight: 500,
                          whiteSpace: "nowrap",
                          borderBottom: "1px solid #e8e4de",
                        }}
                      >
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {txnSlice.map((r, i) => (
                    <tr
                      key={`${r.transaction_id}-${i}`}
                      style={{
                        borderBottom: "1px solid #e8e4de",
                        transition: "background .15s",
                      }}
                      onMouseEnter={(e) => {
                        (e.currentTarget as HTMLElement).style.background =
                          "#f5f2ee";
                      }}
                      onMouseLeave={(e) => {
                        (e.currentTarget as HTMLElement).style.background = "";
                      }}
                    >
                      <td style={{ padding: "9px 12px", whiteSpace: "nowrap" }}>
                        {r.transaction_date?.split("T")[0] ?? "—"}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          whiteSpace: "nowrap",
                          color: "#6b6860",
                          fontSize: 10.5,
                        }}
                      >
                        {r.transaction_date?.split("T")[1]?.slice(0, 5) ?? "—"}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          fontSize: 11,
                          maxWidth: 160,
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                        }}
                      >
                        {r.machines?.official_name || r.machine_id}
                      </td>
                      <td style={{ padding: "9px 12px" }}>
                        {r.machines?.venue_group ? (
                          <span
                            style={{
                              fontSize: 9,
                              padding: "2px 6px",
                              borderRadius: 3,
                              background: `${GROUP_COLORS[r.machines.venue_group] || "#6b6860"}18`,
                              color:
                                GROUP_COLORS[r.machines.venue_group] ||
                                "#6b6860",
                              fontWeight: 500,
                            }}
                          >
                            {r.machines.venue_group}
                          </span>
                        ) : (
                          <span style={{ color: "#9a948e" }}>—</span>
                        )}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          fontFamily:
                            "ui-monospace, SFMono-Regular, Menlo, monospace",
                          fontSize: 10,
                          color: "#6b6860",
                          maxWidth: 120,
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                        }}
                        title={r.psp || undefined}
                      >
                        {r.psp || "—"}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          fontSize: 10.5,
                        }}
                      >
                        {r.funding || (
                          <span style={{ color: "#9a948e" }}>—</span>
                        )}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          fontSize: 10.5,
                        }}
                      >
                        {r.paymentMethod || (
                          <span style={{ color: "#9a948e" }}>—</span>
                        )}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          textAlign: "right",
                          color: r.isWallet ? "#d97706" : "#9a948e",
                          fontWeight: r.isWallet ? 600 : 400,
                        }}
                      >
                        {r.isWallet ? "✓" : "—"}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          textAlign: "right",
                          fontWeight: 500,
                        }}
                      >
                        {fmtAed(r.total_amount)}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          textAlign: "right",
                          color: r.captured > 0 ? "#24544a" : "#9a948e",
                        }}
                      >
                        {r.captured > 0 ? fmtAed(r.captured) : "—"}
                      </td>
                      <td style={{ padding: "9px 12px", textAlign: "right" }}>
                        {r.qty}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          fontSize: 11,
                          maxWidth: 200,
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                        }}
                        title={r.pod_product_name || undefined}
                      >
                        {r.pod_product_name || "—"}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* pagination */}
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "center",
                marginTop: 12,
                fontSize: 11,
              }}
            >
              <span style={{ color: "#6b6860" }}>
                Showing {filteredTxns.length > 0 ? txnPage * PAGE_SIZE + 1 : 0}-
                {Math.min((txnPage + 1) * PAGE_SIZE, filteredTxns.length)} of{" "}
                {fmtN(filteredTxns.length)}
              </span>
              <div style={{ display: "flex", gap: 8 }}>
                <button
                  disabled={txnPage === 0}
                  onClick={() => setTxnPage((p) => p - 1)}
                  style={{
                    padding: "5px 14px",
                    borderRadius: 4,
                    border: "1px solid #e8e4de",
                    background: "#ffffff",
                    color: txnPage === 0 ? "#e8e4de" : "#6b6860",
                    cursor: txnPage === 0 ? "default" : "pointer",
                    fontFamily: font,
                    fontSize: 11,
                  }}
                >
                  Prev
                </button>
                <button
                  disabled={txnPage >= txnPageCount - 1}
                  onClick={() => setTxnPage((p) => p + 1)}
                  style={{
                    padding: "5px 14px",
                    borderRadius: 4,
                    border: "1px solid #e8e4de",
                    background: "#ffffff",
                    color: txnPage >= txnPageCount - 1 ? "#e8e4de" : "#6b6860",
                    cursor: txnPage >= txnPageCount - 1 ? "default" : "pointer",
                    fontFamily: font,
                    fontSize: 11,
                  }}
                >
                  Next
                </button>
              </div>
            </div>
          </div>
        )}

        {/* ── COMMERCIAL ── */}
        {activeTab === "Commercial" && (
          <div>
            <SectionLabel text="FINANCIAL RECONCILIATION" />
            <h2
              style={{
                fontFamily: font,
                fontWeight: 700,
                fontSize: 22,
                letterSpacing: "-0.5px",
                marginBottom: 4,
              }}
            >
              Boonz Commercial Summary
            </h2>
            <p style={{ fontSize: 11, color: "#6b6860", marginBottom: 20 }}>
              {fmtN(matchedCount)} matched &middot;{" "}
              {fmtN(totalCount - matchedCount)} unmatched
            </p>

            {/* scenario badge — DB-driven via activeAgreement */}
            <div style={{ marginBottom: 14 }}>
              {(() => {
                const boonzPct = Math.round(activeAgreement.boonz * 100);
                const partnerPct = Math.round(activeAgreement.partner * 100);
                const partnerName = activeAgreement.partnerName ?? "Partner";
                let label: string;
                let bg: string;
                let color: string;
                let border: string;
                if (activeAgreement.type === "VOX") {
                  label = `VOX Agreement · ${boonzPct}% Boonz / ${partnerPct}% VOX`;
                  bg = "rgba(37,99,235,0.12)";
                  color = "#1d4ed8";
                  border = "#1d4ed8";
                } else if (activeAgreement.type === "REVENUE_SHARE") {
                  label = `${partnerName} Agreement · ${partnerPct}% / ${boonzPct}%`;
                  bg = "rgba(22,163,74,0.12)";
                  color = "#15803d";
                  border = "#15803d";
                } else {
                  label = "No Commercial Agreement";
                  bg = "rgba(107,104,96,0.12)";
                  color = "#6b6860";
                  border = "#d6d2cb";
                }
                return (
                  <span
                    style={{
                      display: "inline-block",
                      padding: "4px 12px",
                      fontSize: 10.5,
                      letterSpacing: "0.08em",
                      textTransform: "uppercase",
                      fontWeight: 600,
                      borderRadius: 999,
                      background: bg,
                      color,
                      border: `1px solid ${border}`,
                      fontFamily: font,
                    }}
                  >
                    {label}
                  </span>
                );
              })()}
            </div>

            {/* 5 unified stat cards (scenario-aware) */}
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(5, 1fr)",
                gap: 14,
                marginBottom: 28,
              }}
            >
              <StatCard
                label="Total Amount"
                value={fmtAed(totalWeimi)}
                subtitle="Gross from Weimi"
                accent="#0E3F4D"
                valueColor="#0E3F4D"
              />
              <StatCard
                label="Captured"
                value={fmtAed(capturedAdyen)}
                subtitle="Settled payments only"
                accent="#0F4D3A"
                valueColor="#0F4D3A"
              />
              <StatCard
                label="Net Revenue"
                value={fmtAed(commercialData.netRevenue)}
                subtitle={`After ${(ADYEN_FEE_PCT * 100).toFixed(2)}% fees (on captured)`}
                accent="#0E3F4D"
                valueColor="#0E3F4D"
              />
              <StatCard
                label="Boonz Revenue"
                value={fmtAed(commercialData.boonzRevenue)}
                subtitle={
                  activeAgreement.type === "NONE"
                    ? "100% — No Agreement"
                    : `Boonz ${Math.round(activeAgreement.boonz * 100)}% Share`
                }
                accent="#0F4D3A"
                valueColor="#0F4D3A"
              />
              <StatCard
                label="Partner Revenue"
                value={fmtAed(commercialData.partnerRevenue)}
                subtitle={
                  activeAgreement.type === "NONE"
                    ? "—"
                    : `${activeAgreement.partnerName ?? "Partner"} ${Math.round(activeAgreement.partner * 100)}% Share`
                }
                accent={
                  commercialData.partnerRevenue > 0 ? "#F59E0B" : "#9CA3AF"
                }
                valueColor={
                  commercialData.partnerRevenue > 0 ? "#d97706" : "#9CA3AF"
                }
              />
            </div>

            {/* by-group breakdown table (above waterfall) */}
            {viewMode === "by-group" && (
              <div
                style={{
                  background: "white",
                  border: "1px solid #e8e4de",
                  borderRadius: 6,
                  overflow: "hidden",
                  marginBottom: 28,
                }}
              >
                <div
                  style={{
                    padding: "14px 20px",
                    borderBottom: "1px solid #e8e4de",
                  }}
                >
                  <h3
                    style={{
                      fontFamily: font,
                      fontWeight: 600,
                      fontSize: 15,
                      margin: 0,
                    }}
                  >
                    By Group Breakdown
                  </h3>
                </div>
                <div style={{ overflowX: "auto" }}>
                  <table
                    style={{
                      width: "100%",
                      borderCollapse: "collapse",
                      fontSize: 11.5,
                      minWidth: 1000,
                    }}
                  >
                    <thead>
                      <tr>
                        {[
                          "Group",
                          "Revenue",
                          "Captured",
                          "Net Rev",
                          "Boonz NR",
                          "Partner NR",
                        ].map((h) => (
                          <th
                            key={h}
                            style={{
                              background: "#f5f2ee",
                              padding: "10px 12px",
                              textAlign: h === "Group" ? "left" : "right",
                              fontSize: 9.5,
                              letterSpacing: ".1em",
                              textTransform: "uppercase",
                              color: "#6b6860",
                              fontWeight: 500,
                              borderBottom: "1px solid #e8e4de",
                            }}
                          >
                            {h}
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {commercialData.groupBreakdown.map((g) => {
                        const partnerNR = Math.max(
                          0,
                          g.netRevenue - g.boonzShare,
                        );
                        return (
                          <tr
                            key={g.name}
                            style={{ borderBottom: "1px solid #e8e4de" }}
                          >
                            <td
                              style={{ padding: "9px 12px", fontWeight: 500 }}
                            >
                              <span
                                style={{
                                  fontSize: 10,
                                  padding: "2px 8px",
                                  borderRadius: 3,
                                  background: `${GROUP_COLORS[g.name] || "#6b6860"}18`,
                                  color: GROUP_COLORS[g.name] || "#6b6860",
                                  fontWeight: 600,
                                }}
                              >
                                {g.name}
                              </span>
                            </td>
                            <td
                              style={{
                                padding: "9px 12px",
                                textAlign: "right",
                                fontWeight: 500,
                              }}
                            >
                              {fmtAed(g.revenue)}
                            </td>
                            <td
                              style={{
                                padding: "9px 12px",
                                textAlign: "right",
                                color: "#24544a",
                              }}
                            >
                              {fmtAed(g.captured)}
                            </td>
                            <td
                              style={{
                                padding: "9px 12px",
                                textAlign: "right",
                              }}
                            >
                              {fmtAed(g.netRevenue)}
                            </td>
                            <td
                              style={{
                                padding: "9px 12px",
                                textAlign: "right",
                                color: "#0F4D3A",
                                fontWeight: 600,
                              }}
                            >
                              {fmtAed(g.boonzShare)}
                            </td>
                            <td
                              style={{
                                padding: "9px 12px",
                                textAlign: "right",
                                color: partnerNR > 0 ? "#d97706" : "#9a948e",
                              }}
                            >
                              {partnerNR > 0 ? fmtAed(partnerNR) : "—"}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* waterfall chart */}
            <div
              style={{
                background: "white",
                border: "1px solid #e8e4de",
                borderRadius: 6,
                padding: "18px 20px",
                marginBottom: 28,
              }}
            >
              <h3
                style={{
                  fontFamily: font,
                  fontWeight: 600,
                  fontSize: 15,
                  marginBottom: 12,
                }}
              >
                Revenue Waterfall
              </h3>
              <ResponsiveContainer width="100%" height={320}>
                <BarChart data={commercialData.waterfallData}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" />
                  <XAxis
                    dataKey="name"
                    tick={{ fontSize: 9, fill: "#6b6860" }}
                    interval={0}
                  />
                  <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
                  <Tooltip
                    contentStyle={{
                      background: "#fff",
                      border: "1px solid #e8e4de",
                      borderRadius: 4,
                      fontSize: 11,
                    }}
                    // eslint-disable-next-line @typescript-eslint/no-explicit-any
                    formatter={(value: any, name: any) => {
                      if (name === "base") return [null, null];
                      return [fmtAed(value), "Amount"];
                    }}
                  />
                  <Bar dataKey="base" stackId="a" fill="transparent" />
                  <Bar dataKey="value" stackId="a" radius={[4, 4, 0, 0]}>
                    {commercialData.waterfallData.map((d, i) => (
                      <Cell key={i} fill={d.fill} />
                    ))}
                    <LabelList
                      dataKey="value"
                      position="top"
                      formatter={(v: unknown) =>
                        typeof v === "number" && v > 0 ? fmtAed(v) : ""
                      }
                      style={{
                        fontSize: 9.5,
                        fill: "#2A3547",
                        fontWeight: 500,
                      }}
                    />
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
              {commercialScenario === "STANDARD" && (
                <div
                  style={{
                    marginTop: 10,
                    padding: "10px 14px",
                    background: "#f5f2ee",
                    borderRadius: 4,
                    fontSize: 11,
                    color: "#6b6860",
                    textAlign: "center",
                  }}
                >
                  Select a specific machine group to view commercial breakdown
                </div>
              )}
            </div>

            {/* full transaction ledger */}
            <div
              style={{
                background: "white",
                border: "1px solid #e8e4de",
                borderRadius: 6,
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  padding: "14px 20px",
                  borderBottom: "1px solid #e8e4de",
                }}
              >
                <h3
                  style={{
                    fontFamily: font,
                    fontWeight: 600,
                    fontSize: 15,
                    margin: 0,
                  }}
                >
                  Full Ledger
                </h3>
                <div style={{ fontSize: 10, color: "#6b6860", marginTop: 4 }}>
                  {fmtN(salesRows.length)} entries
                </div>
              </div>
              <div style={{ overflowX: "auto" }}>
                <table
                  style={{
                    width: "100%",
                    borderCollapse: "collapse",
                    fontSize: 11,
                    minWidth: 1400,
                  }}
                >
                  <thead>
                    <tr>
                      {[
                        "Date",
                        "Machine",
                        "Total",
                        "Paid",
                        "Captured",
                        "Default",
                        "Adyen Fee",
                        "Net Rev",
                        "Boonz NR",
                        "Partner NR",
                      ].map((h) => (
                        <th
                          key={h}
                          style={{
                            background: "#f5f2ee",
                            padding: "8px 10px",
                            textAlign: ["Date", "Machine"].includes(h)
                              ? "left"
                              : "right",
                            fontSize: 9,
                            letterSpacing: ".1em",
                            textTransform: "uppercase",
                            color: "#6b6860",
                            fontWeight: 500,
                            whiteSpace: "nowrap",
                            borderBottom: "1px solid #e8e4de",
                          }}
                        >
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {(() => {
                      // B3: scenario-aware splits — sourced from the active
                      // DB agreement, not hardcoded constants.
                      const boonzShare = activeAgreement.boonz;
                      const partnerShare = activeAgreement.partner;
                      return salesRows.slice(0, 100).map((r, i) => {
                        // B3 Fix 3: look across ALL adyen rows so we can
                        // distinguish "no adyen match at all" (pending) from
                        // "adyen found but not settled" (refused / refunded).
                        const matchedA = adyenRows.find(
                          (a) =>
                            a.machine_id === r.machine_id &&
                            a.creation_date?.split("T")[0] ===
                              r.transaction_date?.split("T")[0],
                        );
                        const adyenStatus = matchedA?.status ?? null;
                        const isSettled =
                          !!adyenStatus && SETTLED_STATUSES.has(adyenStatus);
                        const captured = isSettled
                          ? (matchedA?.captured_amount_value ?? 0)
                          : 0;
                        const defAmt = r.total_amount - captured;
                        const fees = captured * ADYEN_FEE_PCT;
                        const net = captured - fees;
                        const boonzNR = net * boonzShare;
                        const partnerNR = net * partnerShare;
                        const paid =
                          (r as unknown as { paid_amount?: number | null })
                            .paid_amount ?? null;

                        return (
                          <tr
                            key={`${r.transaction_id}-${i}`}
                            style={{ borderBottom: "1px solid #e8e4de" }}
                          >
                            <td
                              style={{
                                padding: "7px 10px",
                                whiteSpace: "nowrap",
                                fontSize: 10,
                              }}
                            >
                              {r.transaction_date?.split("T")[0] ?? "—"}
                            </td>
                            <td
                              style={{
                                padding: "7px 10px",
                                fontSize: 10,
                                maxWidth: 160,
                                overflow: "hidden",
                                textOverflow: "ellipsis",
                                whiteSpace: "nowrap",
                              }}
                            >
                              {r.machines?.official_name || r.machine_id}
                            </td>
                            <td
                              style={{
                                padding: "7px 10px",
                                textAlign: "right",
                                fontWeight: 500,
                              }}
                            >
                              {fmtAed(r.total_amount)}
                            </td>
                            <td
                              style={{
                                padding: "7px 10px",
                                textAlign: "right",
                                color: "#6b6860",
                              }}
                            >
                              {paid != null && paid > 0 ? fmtAed(paid) : "—"}
                            </td>
                            {/* B3 Fix 3: tri-state Captured cell */}
                            <td
                              style={{
                                padding: "7px 10px",
                                textAlign: "right",
                              }}
                            >
                              {!matchedA ? (
                                <span
                                  style={{
                                    color: "#9a948e",
                                    fontStyle: "italic",
                                  }}
                                >
                                  Not found
                                </span>
                              ) : !isSettled ? (
                                <span style={{ color: "#d97706" }}>
                                  AED 0.00 · {adyenStatus}
                                </span>
                              ) : (
                                <span style={{ color: "#24544a" }}>
                                  {fmtAed(captured)}
                                </span>
                              )}
                            </td>
                            {/* B3 Fix 3: tri-state Default cell */}
                            <td
                              style={{
                                padding: "7px 10px",
                                textAlign: "right",
                              }}
                            >
                              {!matchedA ? (
                                <span
                                  style={{ color: "#f59e0b", fontWeight: 600 }}
                                >
                                  Pending
                                </span>
                              ) : !isSettled ? (
                                <span
                                  style={{ color: "#dc2626", fontWeight: 600 }}
                                >
                                  {fmtAed(
                                    r.total_amount -
                                      (matchedA.captured_amount_value ?? 0),
                                  )}
                                </span>
                              ) : defAmt > 0.01 ? (
                                <span
                                  style={{ color: "#dc2626", fontWeight: 600 }}
                                >
                                  {fmtAed(defAmt)}
                                </span>
                              ) : (
                                <span style={{ color: "#9a948e" }}>—</span>
                              )}
                            </td>
                            <td
                              style={{
                                padding: "7px 10px",
                                textAlign: "right",
                                color: "#6366F1",
                              }}
                            >
                              {fees > 0 ? fmtAed(fees) : "—"}
                            </td>
                            <td
                              style={{
                                padding: "7px 10px",
                                textAlign: "right",
                              }}
                            >
                              {net > 0 ? fmtAed(net) : "—"}
                            </td>
                            <td
                              style={{
                                padding: "7px 10px",
                                textAlign: "right",
                                color: "#0F4D3A",
                                fontWeight: 600,
                              }}
                            >
                              {boonzNR > 0 ? fmtAed(boonzNR) : "—"}
                            </td>
                            <td
                              style={{
                                padding: "7px 10px",
                                textAlign: "right",
                                color: partnerNR > 0 ? "#d97706" : "#9a948e",
                              }}
                            >
                              {partnerNR > 0 ? fmtAed(partnerNR) : "—"}
                            </td>
                          </tr>
                        );
                      });
                    })()}
                  </tbody>
                </table>
              </div>
              {salesRows.length > 100 && (
                <div
                  style={{
                    padding: "10px 20px",
                    fontSize: 10,
                    color: "#6b6860",
                    borderTop: "1px solid #e8e4de",
                    textAlign: "center",
                  }}
                >
                  Showing first 100 of {fmtN(salesRows.length)} entries. Use the
                  Transactions tab for full pagination.
                </div>
              )}
            </div>
          </div>
        )}
      </div>

      {/* ── footer ── */}
      <footer
        style={{
          textAlign: "center",
          padding: "28px 24px",
          color: "#6b6860",
          fontSize: 10,
          letterSpacing: ".05em",
          borderTop: "1px solid #e8e4de",
          marginTop: 40,
        }}
      >
        Boonz Performance Dashboard &middot; Data: Weimi + Adyen &middot;{" "}
        {dateFrom} to {dateTo}
      </footer>
    </div>
  );
}
