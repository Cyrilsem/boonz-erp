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
  "Customers",
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
  // customer intelligence fields
  card_number_summary: string | null;
  card_bin: string | null;
  issuer: string | null;
  issuer_country: string | null;
  risk_score: number | null;
  shopper_country: string | null;
}

type CustomerSegment = "Power User" | "Returning" | "One-off" | "Failed" | "Defaulter" | "Compromised" | "Pure Fraud";

interface CustomerProfile {
  key: string;          // "bin-last4" e.g. "531780-3393"
  cardDisplay: string;
  cardBin: string | null;
  last4: string | null;
  paymentMethod: string | null;
  fundingSource: string | null;
  issuer: string | null;
  issuerCountry: string | null;
  txnCount: number;     // total adyen events for this card
  settledCount: number; // adyen SettledBulk rows
  matchedTxns: number;  // adyen rows that resolved to a Weimi basket
  refusedCount: number;
  cancelledCount: number;
  // Revenue = SUM(weimi.total_amount) for matched transactions (user definition)
  totalSpend: number;
  // Gap = SUM(weimi.total_amount) - SUM(adyen.captured_amount_value) for matched
  gap: number;
  avgSpend: number;     // totalSpend / matchedTxns
  firstSeen: string;
  lastSeen: string;
  segment: CustomerSegment;
  isRepeat: boolean;
  machineCount: number;
  maxRiskScore: number;
  hasHighRisk: boolean;
  favoriteStore: string | null;
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
// ── Dubai-timezone helpers ──────────────────────────────────────────────────
// All WEIMI/Adyen timestamps are stored as UTC instants in Postgres.
// These helpers convert to Asia/Dubai (UTC+4, no DST) for display and bucketing.

const DUBAI_TZ = "Asia/Dubai";

function dubaiDateOnly(d: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: DUBAI_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(d);
}
/** Dubai-local YYYY-MM-DD for a stored UTC ISO string */
function dubaiDate(iso: string): string {
  return dubaiDateOnly(new Date(iso));
}
/** Dubai-local HH:MM for a stored UTC ISO string */
function dubaiTime(iso: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: DUBAI_TZ,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(iso));
}
/** Dubai-local hour 0-23 */
function dubaiHour(iso: string): number {
  return parseInt(
    new Intl.DateTimeFormat("en", {
      timeZone: DUBAI_TZ,
      hour: "numeric",
      hour12: false,
    }).format(new Date(iso)),
    10,
  );
}
/** Dubai-local day-of-week 0 (Sun) … 6 (Sat) */
function dubaiDow(iso: string): number {
  const abbr = new Intl.DateTimeFormat("en", {
    timeZone: DUBAI_TZ,
    weekday: "short",
  }).format(new Date(iso));
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(abbr);
}

function daysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return dubaiDateOnly(d); // Dubai-local, not UTC
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
  const [dateTo, setDateTo] = useState(dubaiDateOnly()); // Dubai-local today
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

  // customers tab state
  const [custSearch, setCustSearch] = useState("");
  const [custSort, setCustSort] = useState<"txns" | "spend" | "last_seen" | "risk">("txns");
  const [custSortDir, setCustSortDir] = useState<"desc" | "asc">("desc");
  const [selectedCustKey, setSelectedCustKey] = useState<string | null>(null);
  const [custPage, setCustPage] = useState(0);
  const [custSegFilter, setCustSegFilter] = useState<CustomerSegment | null>(null);
  const CUST_PAGE_SIZE = 50;

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
        .gte("transaction_date", `${dateFrom}T00:00:00+04:00`) // Dubai midnight
        .lte("transaction_date", `${dateTo}T23:59:59+04:00`); // Dubai end-of-day
      if (selectedMachineIds.length > 0) {
        salesQuery = salesQuery.in("machine_id", selectedMachineIds);
      }

      // Adyen settlements post 1-3 days after the Weimi sale.
      // Extend the window ±7 days so edge-of-range baskets always find their match.
      // Do NOT filter by machine_id — that column is NULL in adyen_transactions;
      // machine association is resolved implicitly via merchant_reference matching.
      const adyenFrom = dubaiDateOnly(
        new Date(new Date(dateFrom).getTime() - 7 * 24 * 60 * 60 * 1000),
      );
      const adyenTo = dubaiDateOnly(
        new Date(new Date(dateTo).getTime() + 7 * 24 * 60 * 60 * 1000),
      );
      const adyenQuery = supabase
        .from("adyen_transactions")
        .select(
          "adyen_txn_id, machine_id, creation_date, value_aed, captured_amount_value, status, payment_method, funding_source, store_description, psp_reference, merchant_reference, card_number_summary, card_bin, issuer, issuer_country, risk_score, shopper_country",
        )
        .gte("creation_date", `${adyenFrom}T00:00:00+04:00`) // Dubai midnight
        .lte("creation_date", `${adyenTo}T23:59:59+04:00`); // Dubai end-of-day

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

      // Do not filter Adyen by machine_id (NULL in all rows).
      // Machine association is resolved via merchant_reference matching against
      // salesRows (which IS filtered by group). This mirrors the RPC approach.
      setAdyenRows((adyenRes.data ?? []) as AdyenTxn[]);

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

  // Base txn IDs for every basket in the current machine-group-filtered salesRows.
  // Used to scope Adyen captures/refunds to just the active group — machine_id is
  // NULL in adyen_transactions so we must join via merchant_reference instead.
  const salesBaseTxnSns = useMemo(() => {
    const s = new Set<string>();
    for (const r of salesRows) {
      const base = (r.internal_txn_sn ?? "").replace(/_\d+$/, "");
      if (base) s.add(base);
    }
    return s;
  }, [salesRows]);

  // Adyen rows scoped to the current machine/group filter.
  // adyen_transactions.machine_id is always NULL — the only way to attribute a tap
  // to a specific machine is via merchant_reference ↔ salesBaseTxnSns linkage.
  // Used by the Customers tab so all card data respects the active filter.
  const scopedAdyenRows = useMemo(
    () =>
      adyenRows.filter(
        (r) => r.merchant_reference && salesBaseTxnSns.has(r.merchant_reference),
      ),
    [adyenRows, salesBaseTxnSns],
  );

  // Settled Adyen rows that actually belong to the current salesRows selection.
  const matchedSettledAdyen = useMemo(
    () =>
      settledAdyen.filter(
        (r) =>
          r.merchant_reference && salesBaseTxnSns.has(r.merchant_reference),
      ),
    [settledAdyen, salesBaseTxnSns],
  );

  const capturedAdyen = useMemo(
    () =>
      matchedSettledAdyen.reduce(
        (s, r) => s + (r.captured_amount_value || 0),
        0,
      ),
    [matchedSettledAdyen],
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

  // ── customer intelligence ──
  const customerProfiles = useMemo<CustomerProfile[]>(() => {
    // Step 1: build Weimi lookup — base_txn_sn → total_amount (sum of all lines)
    // Revenue definition: SUM(weimi.total_amount) for txns matched to Adyen by merchant_reference
    const weimiTotalByBase = new Map<string, number>();
    const weimiCapturedByBase = new Map<string, number>(); // from adyen.captured_amount_value
    for (const s of salesRows) {
      if (!s.internal_txn_sn) continue;
      const base = s.internal_txn_sn.replace(/_\d+$/, "");
      if (!base) continue;
      weimiTotalByBase.set(base, (weimiTotalByBase.get(base) ?? 0) + (s.total_amount ?? 0));
    }
    // Also build adyen captured per merchant_reference (for gap calc)
    // Use scopedAdyenRows so captured totals stay within the active machine/group filter
    for (const a of scopedAdyenRows) {
      if (!a.merchant_reference) continue;
      if (!SETTLED_STATUSES.has(a.status ?? "")) continue;
      weimiCapturedByBase.set(
        a.merchant_reference,
        (weimiCapturedByBase.get(a.merchant_reference) ?? 0) + (a.captured_amount_value ?? 0)
      );
    }

    type Internal = CustomerProfile & { _machines: Set<string>; _ff: number };
    const map = new Map<string, Internal>();

    // scopedAdyenRows is already filtered to the active machine/group via salesBaseTxnSns
    for (const row of scopedAdyenRows) {
      // Strip .0 numeric storage artefact (e.g. "559917.0" → "559917")
      const bin  = row.card_bin  ? String(row.card_bin).replace(/\.0$/, "").trim()  : null;
      const last4 = row.card_number_summary ? String(row.card_number_summary).replace(/\.0$/, "").trim() : null;
      if (!bin || !last4 || bin === "0" || last4 === "0") continue;

      const key = `${bin}-${last4}`;
      const isSettled = SETTLED_STATUSES.has(row.status ?? "");
      const risk = row.risk_score ?? 0;
      const ff = risk > 50;

      // Revenue: Weimi total_amount for this transaction (only when merchant_reference links to Weimi)
      const base = row.merchant_reference ?? null;
      const weimiAmt  = base ? (weimiTotalByBase.get(base) ?? 0)    : 0;
      const captAmt   = base && isSettled ? (weimiCapturedByBase.get(base) ?? 0) : 0;
      // Round to 2 d.p. before gap test — IEEE 754 float accumulation on multi-line
      // baskets (e.g. 0.68+2.81=3.4900000000000002) produces phantom sub-cent remainders
      // that would falsely classify clean cards as Defaulters.
      const gapAmt    = weimiAmt > 0 ? Math.round(Math.max(weimiAmt - captAmt, 0) * 100) / 100 : 0;
      const isMatched = base != null && weimiTotalByBase.has(base);

      const existing = map.get(key);
      if (!existing) {
        map.set(key, {
          key,
          cardDisplay: key,
          cardBin: bin,
          last4,
          paymentMethod: row.payment_method ?? null,
          fundingSource: row.funding_source ?? null,
          issuer: row.issuer ?? null,
          issuerCountry: row.issuer_country ?? null,
          txnCount: 1,
          settledCount: isSettled ? 1 : 0,
          matchedTxns: isMatched ? 1 : 0,
          refusedCount: row.status === "Refused" ? 1 : 0,
          cancelledCount: row.status === "Cancelled" ? 1 : 0,
          totalSpend: weimiAmt,
          gap: gapAmt,
          avgSpend: 0,
          firstSeen: row.creation_date,
          lastSeen: row.creation_date,
          segment: "One-off",
          isRepeat: false,
          machineCount: 0,
          maxRiskScore: risk,
          hasHighRisk: ff,
          favoriteStore: row.store_description ?? null,
          _machines: new Set(row.machine_id ? [row.machine_id] : []),
          _ff: ff ? 1 : 0,
        });
      } else {
        existing.txnCount++;
        if (isSettled) existing.settledCount++;
        if (isMatched) existing.matchedTxns++;
        if (row.status === "Refused") existing.refusedCount++;
        if (row.status === "Cancelled") existing.cancelledCount++;
        existing.totalSpend += weimiAmt;
        existing.gap += gapAmt;
        if (row.creation_date < existing.firstSeen) existing.firstSeen = row.creation_date;
        if (row.creation_date > existing.lastSeen) existing.lastSeen = row.creation_date;
        if (risk > existing.maxRiskScore) existing.maxRiskScore = risk;
        if (ff) { existing.hasHighRisk = true; existing._ff++; }
        if (row.machine_id) existing._machines.add(row.machine_id);
      }
    }

    return Array.from(map.values()).map((cp) => {
      const s = cp.settledCount;
      const ff = cp._ff;
      let segment: CustomerSegment;
      if (ff >= 3)                       segment = "Compromised";
      else if (ff > 0 && s === 0)        segment = "Pure Fraud";
      else if (ff > 0)                   segment = "Compromised";
      else if (cp.gap >= 0.01 && s > 0)   segment = "Defaulter"; // ≥1 cent, mirrors txnMatchStats threshold
      else if (s === 0)                  segment = "Failed";
      else if (s >= 5)                   segment = "Power User";
      else if (s >= 2)                   segment = "Returning";
      else                               segment = "One-off";
      return {
        ...cp,
        segment,
        isRepeat: s > 1,
        avgSpend: cp.matchedTxns > 0 ? cp.totalSpend / cp.matchedTxns : 0,
        machineCount: cp._machines.size,
      };
    });
  }, [scopedAdyenRows, salesRows]);

  const txnMatchStats = useMemo(() => {
    // Group individual sales lines into basket-level transactions
    const groups = new Map<string, { total: number }>();
    for (const s of salesRows) {
      const base = (s.internal_txn_sn ?? "").replace(/_\d+$/, "");
      if (!base) continue;
      // Mirror the RPC's vox_sales filter: skip zero-amount rows (cash /
      // cancelled-before-capture). They inflate basket count and distort the rate.
      const effectiveTotal =
        (s.total_amount ?? 0) > 0
          ? (s.total_amount ?? 0)
          : (s.paid_amount ?? 0);
      if (effectiveTotal <= 0) continue;
      const g = groups.get(base);
      if (g) {
        g.total += effectiveTotal;
      } else groups.set(base, { total: effectiveTotal });
    }
    // Mirror RPC default_stats: WHERE psp_reference IS NOT NULL
    // Any Adyen record = matched, regardless of status.
    // gap = MAX(weimi_total - COALESCE(captured, 0), 0) per basket.
    // defaultPct = gap / matched_weimi (not total weimi).
    let matchedTotal = 0;
    let matchedCapture = 0;
    let matchedCount = 0;
    let defaultGap = 0;
    let defaultBasketCount = 0;
    for (const [base, grp] of groups) {
      const adyen = adyenByMerchantRef.get(base);
      if (adyen !== undefined) {
        // psp_reference IS NOT NULL
        const captured = adyen.captured_amount_value ?? 0;
        matchedTotal += grp.total;
        matchedCapture += captured;
        matchedCount++;
        const gap = Math.max(grp.total - captured, 0);
        defaultGap += gap;
        if (gap > 0.01) defaultBasketCount++;
      }
    }
    return {
      matchedCount,
      totalCount: groups.size,
      matchedCapture,
      gap: defaultGap,
      defaultPct: matchedTotal > 0 ? (defaultGap / matchedTotal) * 100 : 0,
      defaultBasketCount,
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
      const d = r.transaction_date ? dubaiDate(r.transaction_date) : "";
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
      // Use Dubai-local date string to build the Date so weekKey uses the right day
      const d = r.transaction_date
        ? new Date(dubaiDate(r.transaction_date) + "T00:00:00")
        : new Date(r.transaction_date);
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
      const h = dubaiHour(r.transaction_date);
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
      const d = dubaiDow(r.transaction_date);
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
      const d = r.transaction_date ? dubaiDate(r.transaction_date) : "";
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
    // Mirror the RPC: match = psp_reference IS NOT NULL (any Adyen record).
    // isDefault = matched but captured < weimi_total (positive gap only).
    // Unmatched rows are NOT defaults — they are simply excluded from the gap calc.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let rows: any[] = salesRows.map((s) => {
      const base = (s.internal_txn_sn ?? "").replace(/_\d+$/, "");
      const matchedAny = base ? adyenByMerchantRef.get(base) : undefined;
      const status = matchedAny?.status ?? null;
      const captured = matchedAny?.captured_amount_value ?? 0;
      const effectiveTotal =
        (s.total_amount ?? 0) > 0
          ? (s.total_amount ?? 0)
          : (s.paid_amount ?? 0);
      return {
        ...s,
        captured: matchedAny !== undefined ? captured : 0,
        funding: matchedAny?.funding_source || "",
        adyenStatus: status || "",
        psp: matchedAny?.psp_reference || "",
        paymentMethod: matchedAny?.payment_method || "",
        isWallet: (matchedAny?.funding_source || "").toUpperCase() === "WALLET",
        // Default = matched basket where Adyen captured less than Weimi charged
        isDefault: matchedAny !== undefined && captured < effectiveTotal - 0.01,
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

  // defaultBasketCount lives inside txnMatchStats (basket-level, mirrors RPC disc_count).
  const defaultTxnCount = txnMatchStats.defaultBasketCount;

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
    // Refunds scoped to salesRows baskets only (machine_id is NULL in adyen_transactions)
    const refunds = adyenRows
      .filter(
        (r) =>
          r.status === "RefundedBulk" &&
          r.merchant_reference &&
          salesBaseTxnSns.has(r.merchant_reference),
      )
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
    // machine_id is NULL in adyen_transactions, so we match via merchant_reference
    // against the salesRows baskets for each group's machines.
    const groupBreakdown = groupData.map((g) => {
      const groupMachineIds = new Set(
        machineList
          .filter((mm) => mm.venue_group === g.name)
          .map((mm) => mm.machine_id),
      );
      const gBaseSns = new Set<string>();
      for (const r of salesRows) {
        if (groupMachineIds.has(r.machine_id)) {
          const base = (r.internal_txn_sn ?? "").replace(/_\d+$/, "");
          if (base) gBaseSns.add(base);
        }
      }
      const gAdyen = settledAdyen.filter(
        (a) => a.merchant_reference && gBaseSns.has(a.merchant_reference),
      );
      const gCaptured = gAdyen.reduce(
        (s, r) => s + (r.captured_amount_value || 0),
        0,
      );
      const gFees = gCaptured * ADYEN_FEE_PCT;
      const gRefunds = adyenRows
        .filter(
          (rw) =>
            rw.status === "RefundedBulk" &&
            rw.merchant_reference &&
            gBaseSns.has(rw.merchant_reference),
        )
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
    salesBaseTxnSns,
    salesRows,
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
            AED {fmtN(txnMatchStats.matchedCapture)}
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
                        {r.transaction_date ? dubaiDate(r.transaction_date) : "—"}
                      </td>
                      <td
                        style={{
                          padding: "9px 12px",
                          whiteSpace: "nowrap",
                          color: "#6b6860",
                          fontSize: 10.5,
                        }}
                      >
                        {r.transaction_date ? dubaiTime(r.transaction_date) : "—"}
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

        {/* ── CUSTOMERS ── */}
        {activeTab === "Customers" && (() => {
          // ── derived data for this tab ──
          // "Identified customers" = distinct BINs (card families), per user definition
          const uniqueBins = new Set(customerProfiles.map((c) => c.cardBin)).size;
          const powerUsers  = customerProfiles.filter((c) => c.segment === "Power User");
          const highRiskTxns = scopedAdyenRows.filter((r) => (r.risk_score ?? 0) > 50).length;
          // Revenue = SUM(weimi.total_amount) for matched txns — per user definition
          const totalCustSpend = customerProfiles.reduce((s, c) => s + c.totalSpend, 0);
          const totalMatchedTxns = customerProfiles.reduce((s, c) => s + c.matchedTxns, 0);
          // Avg = totalSpend / number of matched transactions (not cards)
          const avgSpendPerTxn = totalMatchedTxns > 0 ? totalCustSpend / totalMatchedTxns : 0;
          const totalGap = customerProfiles.reduce((s, c) => s + c.gap, 0);
          const repeatCount = customerProfiles.filter((c) => c.isRepeat).length;
          const repeatPct = customerProfiles.length > 0 ? Math.round((repeatCount / customerProfiles.length) * 100) : 0;

          // segment summary for table at top
          const segSummary: Record<string, { cards: number; txns: number; revenue: number }> = {};
          for (const cp of customerProfiles) {
            if (!segSummary[cp.segment]) segSummary[cp.segment] = { cards: 0, txns: 0, revenue: 0 };
            segSummary[cp.segment].cards++;
            segSummary[cp.segment].txns += cp.txnCount;
            segSummary[cp.segment].revenue += cp.totalSpend;
          }
          const SEG_ORDER: CustomerSegment[] = ["Power User","Returning","One-off","Failed","Defaulter","Compromised","Pure Fraud"];
          const SEG_COLORS: Record<string, string> = {
            "Power User": "#24544a", "Returning": "#6366F1", "One-off": "#0E3F4D",
            "Failed": "#9a948e", "Defaulter": "#f97316", "Compromised": "#DC2626", "Pure Fraud": "#7f1d1d",
          };

          // BIN-level frequency (top 12 by revenue)
          const binMap: Record<string, { bin: string; issuer: string; cards: number; txns: number; revenue: number; fraud: number }> = {};
          for (const cp of customerProfiles) {
            const bin = cp.cardBin ?? "Unknown";
            if (!binMap[bin]) binMap[bin] = { bin, issuer: cp.issuer ?? bin, cards: 0, txns: 0, revenue: 0, fraud: 0 };
            binMap[bin].cards++;
            binMap[bin].txns += cp.txnCount;
            binMap[bin].revenue += cp.totalSpend;
            if (cp.hasHighRisk) binMap[bin].fraud++;
          }
          const shortenIssuer = (s: string) =>
            s.replace(/\s*\(P\.?J\.?S\.?C\.?\)/gi, "").replace(/\s+BANK\b/gi, " Bk")
             .replace(/\bBANK\b/gi, "Bk").replace(/\bPAYMENTS LIMITED\b/gi, "Pay")
             .replace(/\bBUILDING SOCIETY\b/gi, "BS").replace(/\s{2,}/g, " ").trim().slice(0, 24);
          const binData = Object.values(binMap)
            .sort((a, b) => b.revenue - a.revenue)
            .slice(0, 12)
            .map((b) => ({ ...b, label: shortenIssuer(b.issuer) }));

          // data coverage: two Adyen populations in the DB
          // Use raw adyenRows here so the banner always shows the full window coverage,
          // not just the scoped subset (helps diagnose pipeline gaps)
          const settledRows = adyenRows.filter((r) => SETTLED_STATUSES.has(r.status ?? ""));
          const identifiedSettled = settledRows.filter((r) => r.card_number_summary);
          const anonymousSettled = settledRows.filter((r) => !r.card_number_summary);
          const identifiedRevenue = identifiedSettled.reduce((s, r) => s + (r.value_aed ?? 0), 0);
          const anonymousRevenue = anonymousSettled.reduce((s, r) => s + (r.value_aed ?? 0), 0);
          const totalSettledRevenue = identifiedRevenue + anonymousRevenue;
          const coveredPct = totalSettledRevenue > 0 ? Math.round((identifiedRevenue / totalSettledRevenue) * 100) : 0;

          // hour-of-day buckets (24h, Dubai TZ, settled txns only) — scoped to filter
          const hourBuckets: number[] = Array(24).fill(0);
          for (const r of scopedAdyenRows) {
            if (!SETTLED_STATUSES.has(r.status ?? "")) continue;
            hourBuckets[dubaiHour(r.creation_date)]++;
          }
          const hourData = hourBuckets.map((count, h) => ({
            hour: `${String(h).padStart(2, "0")}:00`,
            txns: count,
          }));

          // issuer country top-10 — scoped to filter
          const countryMap: Record<string, number> = {};
          for (const r of scopedAdyenRows) {
            if (!SETTLED_STATUSES.has(r.status ?? "")) continue;
            const c = r.issuer_country ?? "Unknown";
            countryMap[c] = (countryMap[c] ?? 0) + 1;
          }
          const countryData = Object.entries(countryMap)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 10)
            .map(([country, count]) => ({ country, count }));

          // visit-frequency buckets
          const freqBuckets = { "1": 0, "2–3": 0, "4–10": 0, "10+": 0 };
          for (const cp of customerProfiles) {
            if (cp.settledCount === 1) freqBuckets["1"]++;
            else if (cp.settledCount <= 3) freqBuckets["2–3"]++;
            else if (cp.settledCount <= 10) freqBuckets["4–10"]++;
            else freqBuckets["10+"]++;
          }
          const freqData = Object.entries(freqBuckets).map(([label, count]) => ({ label, count }));

          // new vs repeat by payment method (for stacked chart)
          const repeatVsNewData = [
            { label: "New (1 visit)", count: customerProfiles.filter((c) => !c.isRepeat).length, fill: "#24544a" },
            { label: "Repeat (2+ visits)", count: repeatCount, fill: "#e1b460" },
          ];

          // ── customer list derivation ──
          const custSearchLow = custSearch.toLowerCase();
          const filteredCusts = customerProfiles.filter((cp) => {
            if (custSegFilter && cp.segment !== custSegFilter) return false;
            if (!custSearchLow) return true;
            return (
              cp.cardDisplay.toLowerCase().includes(custSearchLow) ||
              (cp.paymentMethod ?? "").toLowerCase().includes(custSearchLow) ||
              (cp.issuer ?? "").toLowerCase().includes(custSearchLow) ||
              (cp.issuerCountry ?? "").toLowerCase().includes(custSearchLow)
            );
          });
          const sortedCusts = [...filteredCusts].sort((a, b) => {
            let av = 0, bv = 0;
            if (custSort === "txns") { av = a.settledCount; bv = b.settledCount; }
            else if (custSort === "spend") { av = a.totalSpend; bv = b.totalSpend; }
            else if (custSort === "last_seen") { av = new Date(a.lastSeen).getTime(); bv = new Date(b.lastSeen).getTime(); }
            else { av = a.maxRiskScore; bv = b.maxRiskScore; }
            return custSortDir === "desc" ? bv - av : av - bv;
          });
          const custPageCount = Math.max(1, Math.ceil(sortedCusts.length / CUST_PAGE_SIZE));
          const safeCustPage = Math.min(custPage, custPageCount - 1);
          const pagedCusts = sortedCusts.slice(safeCustPage * CUST_PAGE_SIZE, (safeCustPage + 1) * CUST_PAGE_SIZE);

          // ── selected customer detail ──
          const selectedCust = selectedCustKey ? customerProfiles.find((c) => c.key === selectedCustKey) ?? null : null;
          const selectedTxns = selectedCustKey
            ? scopedAdyenRows
                .filter((r) => {
                  const b = r.card_bin ? String(r.card_bin).replace(/\.0$/, "").trim() : null;
                  const l = r.card_number_summary ? String(r.card_number_summary).replace(/\.0$/, "").trim() : null;
                  return b && l && `${b}-${l}` === selectedCustKey;
                })
                .sort((a, b) => new Date(b.creation_date).getTime() - new Date(a.creation_date).getTime())
            : [];
          // daily spend for selected customer sparkline
          const custDailyMap: Record<string, number> = {};
          for (const r of selectedTxns) {
            if (!SETTLED_STATUSES.has(r.status ?? "")) continue;
            const d = dubaiDate(r.creation_date);
            custDailyMap[d] = (custDailyMap[d] ?? 0) + (r.captured_amount_value ?? 0);
          }
          const custDailyData = Object.entries(custDailyMap).sort().map(([date, amount]) => ({ date, amount }));
          // hour pattern for selected customer
          const custHourBuckets: number[] = Array(24).fill(0);
          for (const r of selectedTxns) {
            if (!SETTLED_STATUSES.has(r.status ?? "")) continue;
            custHourBuckets[dubaiHour(r.creation_date)]++;
          }
          const custHourData = custHourBuckets.map((count, h) => ({ hour: `${String(h).padStart(2, "0")}`, txns: count }));

          // Captured total for selected customer detail KPIs
          const selectedCapture = Math.round(
            selectedTxns
              .filter((r) => SETTLED_STATUSES.has(r.status ?? ""))
              .reduce((s, r) => s + (r.captured_amount_value ?? 0), 0) * 100
          ) / 100;
          const selectedDetailGap = Math.round(
            Math.max((selectedCust?.totalSpend ?? 0) - selectedCapture, 0) * 100
          ) / 100;

          // Weimi product join for selected customer
          // adyen merchant_reference = internal_txn_sn (base, no trailing _N suffix)
          const custMerchantRefs = new Set(
            selectedTxns
              .filter((r) => r.merchant_reference)
              .map((r) => r.merchant_reference as string)
          );
          // salesRows internal_txn_sn may have _1, _2 suffixes — strip them for matching
          const custWeimi = salesRows.filter((s) => {
            const base = (s.internal_txn_sn ?? "").replace(/_\d+$/, "");
            return base && custMerchantRefs.has(base);
          }).sort((a, b) => new Date(b.transaction_date).getTime() - new Date(a.transaction_date).getTime());
          // aggregate by product
          const weimiProductMap: Record<string, { name: string; qty: number; spend: number }> = {};
          for (const s of custWeimi) {
            const name = s.pod_product_name ?? "Unknown";
            if (!weimiProductMap[name]) weimiProductMap[name] = { name, qty: 0, spend: 0 };
            weimiProductMap[name].qty += s.qty ?? 0;
            weimiProductMap[name].spend += s.total_amount ?? 0;
          }
          const weimiTopProducts = Object.values(weimiProductMap)
            .sort((a, b) => b.spend - a.spend)
            .slice(0, 10);

          // shared styles
          const chartCard = {
            background: "white" as const,
            border: "1px solid #e8e4de",
            borderRadius: 6,
            padding: "18px 20px",
          };
          const sortPillStyle = (active: boolean) => ({
            padding: "5px 12px",
            borderRadius: 4,
            border: `1px solid ${active ? "#24544a" : "#e8e4de"}`,
            background: active ? "rgba(36,84,74,0.12)" : "#ffffff",
            color: active ? "#24544a" : "#9a948e",
            fontSize: 11,
            fontFamily: font,
            cursor: "pointer" as const,
            transition: "all .15s",
          });
          const thStyle: React.CSSProperties = {
            textAlign: "left",
            fontWeight: 700,
            fontSize: 10,
            letterSpacing: "0.08em",
            textTransform: "uppercase",
            color: "#6b6860",
            padding: "8px 12px",
            borderBottom: "1px solid #e8e4de",
            whiteSpace: "nowrap",
          };
          const tdStyle: React.CSSProperties = {
            padding: "10px 12px",
            fontSize: 12,
            fontFamily: font,
            borderBottom: "1px solid #f5f2ee",
            whiteSpace: "nowrap",
          };

          return (
            <div>
              <SectionLabel text={`${dateFrom} to ${dateTo} \u00B7 CUSTOMER INTELLIGENCE`} />
              <h2 style={{ fontFamily: font, fontWeight: 700, fontSize: 22, letterSpacing: "-0.5px", marginBottom: 4 }}>
                Customer Profiles
              </h2>
              <p style={{ fontSize: 11, color: "#6b6860", marginBottom: 14 }}>
                {fmtN(customerProfiles.length)} identified customers &middot; {fmtN(settledRows.length)} total settled Adyen transactions in window
              </p>

              {/* ── KPI row ── */}
              <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: 14, marginBottom: 20 }}>
                <StatCard label="Distinct BINs" value={fmtN(uniqueBins)} subtitle="card families (issuer groups)" accent="#24544a" valueColor="#24544a" />
                <StatCard label="Est. Customers" value={fmtN(customerProfiles.length)} subtitle={`avg ${(customerProfiles.length / Math.max(uniqueBins, 1)).toFixed(1)} cards per BIN`} accent="#24544a" valueColor="#24544a" />
                <StatCard label="Power Users (5+ txns)" value={fmtN(powerUsers.length)} subtitle={`${pct(powerUsers.length, customerProfiles.length)} of cards · ${pct(powerUsers.reduce((s,c)=>s+c.totalSpend,0), totalCustSpend)} of revenue`} accent="#0E3F4D" valueColor="#0E3F4D" />
                <StatCard label="Total Billed (Weimi)" value={fmtAed(totalCustSpend)} subtitle={`${fmtN(totalMatchedTxns)} matched txns`} accent="#6366F1" valueColor="#6366F1" />
                <StatCard label="Avg Spend / Visit" value={fmtAed(avgSpendPerTxn)} subtitle="Weimi total ÷ matched txns" accent="#8B5CF6" valueColor="#8B5CF6" />
                <StatCard label="Capture Gap" value={fmtAed(totalGap)} subtitle={`billed minus Adyen captured`} accent={totalGap > 0 ? "#DC2626" : "#6b6860"} valueColor={totalGap > 0 ? "#DC2626" : "#0a0a0a"} />
              </div>

              {/* ── Segment summary table ── */}
              <div style={{ background: "white", border: "1px solid #e8e4de", borderRadius: 6, marginBottom: 20, overflow: "hidden" }}>
                <div style={{ padding: "12px 18px", borderBottom: "1px solid #e8e4de", display: "flex", alignItems: "center", gap: 10 }}>
                  <h3 style={{ fontFamily: font, fontWeight: 700, fontSize: 13, margin: 0 }}>Customer Segments</h3>
                  <span style={{ fontSize: 10, color: "#6b6860" }}>Dossier methodology · settled≥5=Power User · 2-4=Returning · 1=One-off · 0=Failed · gap=Defaulter · risk{">"}50=Compromised</span>
                </div>
                <table style={{ width: "100%", borderCollapse: "collapse", fontFamily: font }}>
                  <thead style={{ background: "#f9f7f4" }}>
                    <tr>
                      <th style={{ textAlign: "left", fontWeight: 700, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", padding: "8px 16px", borderBottom: "1px solid #e8e4de" }}>Segment</th>
                      <th style={{ textAlign: "right", fontWeight: 700, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", padding: "8px 16px", borderBottom: "1px solid #e8e4de" }}>Cards</th>
                      <th style={{ textAlign: "right", fontWeight: 700, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", padding: "8px 16px", borderBottom: "1px solid #e8e4de" }}>% Cards</th>
                      <th style={{ textAlign: "right", fontWeight: 700, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", padding: "8px 16px", borderBottom: "1px solid #e8e4de" }}>Txns</th>
                      <th style={{ textAlign: "right", fontWeight: 700, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", padding: "8px 16px", borderBottom: "1px solid #e8e4de" }}>Revenue</th>
                      <th style={{ textAlign: "right", fontWeight: 700, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", padding: "8px 16px", borderBottom: "1px solid #e8e4de" }}>% Revenue</th>
                      <th style={{ textAlign: "right", fontWeight: 700, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", padding: "8px 16px", borderBottom: "1px solid #e8e4de" }}>Avg / Card</th>
                    </tr>
                  </thead>
                  <tbody>
                    {SEG_ORDER.filter((s) => segSummary[s]).map((seg) => {
                      const d = segSummary[seg];
                      const color = SEG_COLORS[seg] ?? "#6b6860";
                      const isActive = custSegFilter === seg;
                      return (
                        <tr
                          key={seg}
                          onClick={() => { setCustSegFilter(isActive ? null : seg as CustomerSegment); setCustPage(0); }}
                          style={{ borderBottom: "1px solid #f5f2ee", cursor: "pointer", background: isActive ? `${color}12` : "white", transition: "background .1s" }}
                          onMouseEnter={(e) => { if (!isActive) (e.currentTarget as HTMLTableRowElement).style.background = "#fafaf8"; }}
                          onMouseLeave={(e) => { (e.currentTarget as HTMLTableRowElement).style.background = isActive ? `${color}12` : "white"; }}
                        >
                          <td style={{ padding: "9px 16px", fontFamily: font }}>
                            <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
                              <span style={{ width: 8, height: 8, borderRadius: 2, background: color, flexShrink: 0 }} />
                              <span style={{ fontSize: 12, fontWeight: 600, color }}>{seg}</span>
                              {isActive && <span style={{ fontSize: 9, fontWeight: 700, color, background: `${color}22`, padding: "1px 6px", borderRadius: 999, marginLeft: 4 }}>FILTERED ✕</span>}
                            </span>
                          </td>
                          <td style={{ padding: "9px 16px", textAlign: "right", fontSize: 12, fontWeight: 700 }}>{fmtN(d.cards)}</td>
                          <td style={{ padding: "9px 16px", textAlign: "right", fontSize: 11, color: "#6b6860" }}>{pct(d.cards, customerProfiles.length)}</td>
                          <td style={{ padding: "9px 16px", textAlign: "right", fontSize: 12 }}>{fmtN(d.txns)}</td>
                          <td style={{ padding: "9px 16px", textAlign: "right", fontSize: 12, fontWeight: 700, color }}>{fmtAed(d.revenue)}</td>
                          <td style={{ padding: "9px 16px", textAlign: "right", fontSize: 11, color: "#6b6860" }}>{pct(d.revenue, totalCustSpend)}</td>
                          <td style={{ padding: "9px 16px", textAlign: "right", fontSize: 11, color: "#6b6860" }}>{d.cards > 0 ? fmtAed(d.revenue / d.cards) : "—"}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>

              {/* ── Charts row 1: BIN frequency + Time of Day ── */}
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14, marginBottom: 14 }}>
                <div style={chartCard}>
                  <h3 style={{ fontFamily: font, fontWeight: 600, fontSize: 15, marginBottom: 4 }}>Top Card Families by Revenue</h3>
                  <p style={{ fontSize: 10, color: "#6b6860", marginBottom: 14 }}>Weimi billed revenue by issuer · hover for BIN + card count</p>
                  <ResponsiveContainer width="100%" height={280}>
                    <BarChart data={binData} layout="vertical" margin={{ top: 0, right: 64, bottom: 0, left: 0 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" horizontal={false} />
                      <XAxis type="number" tick={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} tickFormatter={(v) => `AED ${fmtN(v)}`} />
                      <YAxis type="category" dataKey="label" tick={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} width={140} />
                      <Tooltip contentStyle={{ fontFamily: font, fontSize: 11, border: "1px solid #e8e4de", borderRadius: 4 }}
                        formatter={(v: any, _name: any, props: any) => {
                          const d = props.payload;
                          return [`${fmtAed(v)} · BIN ${d.bin} · ${fmtN(d.cards)} cards · ${fmtN(d.txns)} txns${d.fraud > 0 ? ` · ⚠ ${d.fraud} fraud` : ""}`, d.issuer];
                        }}
                      />
                      <Bar dataKey="revenue" radius={[0, 3, 3, 0]}>
                        {binData.map((b, i) => <Cell key={i} fill={b.fraud > 0 ? "#DC2626" : "#24544a"} opacity={b.fraud > 0 ? 1 : 0.9 - i * 0.03} />)}
                        <LabelList dataKey="revenue" position="right" style={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} formatter={(v: any) => fmtAed(v)} />
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                  <p style={{ fontSize: 10, color: "#DC2626", marginTop: 8 }}>Red bars = issuer has ≥1 fraud-flagged card in this window</p>
                </div>

                <div style={chartCard}>
                  <h3 style={{ fontFamily: font, fontWeight: 600, fontSize: 15, marginBottom: 4 }}>Time of Day</h3>
                  <p style={{ fontSize: 10, color: "#6b6860", marginBottom: 14 }}>Hour customers transact (Dubai time · all Adyen settled)</p>
                  <ResponsiveContainer width="100%" height={200}>
                    <BarChart data={hourData} margin={{ top: 0, right: 4, bottom: 0, left: -20 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" vertical={false} />
                      <XAxis dataKey="hour" tick={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} interval={3} />
                      <YAxis tick={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} />
                      <Tooltip contentStyle={{ fontFamily: font, fontSize: 11, border: "1px solid #e8e4de", borderRadius: 4 }} formatter={(v: any) => [`${v} txns`, "Transactions"]} />
                      <Bar dataKey="txns" fill="#24544a" radius={[2, 2, 0, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                  <div style={{ marginTop: 14 }}>
                    <p style={{ fontSize: 10, color: "#6b6860", marginBottom: 8 }}>Visit frequency distribution (identified cards)</p>
                    <ResponsiveContainer width="100%" height={120}>
                      <BarChart data={freqData} margin={{ top: 0, right: 4, bottom: 0, left: -20 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" vertical={false} />
                        <XAxis dataKey="label" tick={{ fontSize: 10, fontFamily: font, fill: "#6b6860" }} />
                        <YAxis tick={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} />
                        <Tooltip contentStyle={{ fontFamily: font, fontSize: 11, border: "1px solid #e8e4de", borderRadius: 4 }} formatter={(v: any) => [`${v} cards`, "Cards"]} />
                        <Bar dataKey="count" radius={[3, 3, 0, 0]}>
                          {freqData.map((_, i) => <Cell key={i} fill={i === 0 ? "#9a948e" : i === 1 ? "#6366F1" : i === 2 ? "#24544a" : "#e1b460"} />)}
                        </Bar>
                      </BarChart>
                    </ResponsiveContainer>
                  </div>
                </div>
              </div>

              {/* ── Charts row 2: Issuer Countries ── */}
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14, marginBottom: 24 }}>
                <div style={chartCard}>
                  <h3 style={{ fontFamily: font, fontWeight: 600, fontSize: 15, marginBottom: 4 }}>Issuer Countries</h3>
                  <p style={{ fontSize: 10, color: "#6b6860", marginBottom: 14 }}>Top 10 card-issuing countries by settled transaction count</p>
                  <ResponsiveContainer width="100%" height={240}>
                    <BarChart data={countryData} layout="vertical" margin={{ top: 0, right: 20, bottom: 0, left: 40 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" horizontal={false} />
                      <XAxis type="number" tick={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} />
                      <YAxis type="category" dataKey="country" tick={{ fontSize: 10, fontFamily: font, fill: "#6b6860" }} width={36} />
                      <Tooltip contentStyle={{ fontFamily: font, fontSize: 11, border: "1px solid #e8e4de", borderRadius: 4 }} formatter={(v: any) => [`${v} txns`, "Transactions"]} />
                      <Bar dataKey="count" fill="#0E3F4D" radius={[0, 3, 3, 0]}>
                        <LabelList dataKey="count" position="right" style={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} />
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                </div>

              </div>

              {/* ── Customer List ── */}
              <div style={{ background: "white", border: "1px solid #e8e4de", borderRadius: 6, overflow: "hidden", marginBottom: selectedCust ? 0 : 0 }}>
                <div style={{ padding: "14px 18px", borderBottom: "1px solid #e8e4de", display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
                  <h3 style={{ fontFamily: font, fontWeight: 700, fontSize: 14, margin: 0 }}>
                    {custSegFilter ? custSegFilter : "All Customers"}
                  </h3>
                  {custSegFilter && (
                    <button onClick={() => { setCustSegFilter(null); setCustPage(0); }} style={{ fontSize: 10, fontWeight: 600, color: SEG_COLORS[custSegFilter], background: `${SEG_COLORS[custSegFilter]}18`, border: `1px solid ${SEG_COLORS[custSegFilter]}44`, padding: "2px 10px", borderRadius: 999, cursor: "pointer", fontFamily: font }}>
                      {custSegFilter} ✕ clear
                    </button>
                  )}
                  <span style={{ fontSize: 11, color: "#6b6860" }}>{fmtN(filteredCusts.length)} results</span>
                  <input
                    type="text"
                    placeholder="Search card, method, issuer…"
                    value={custSearch}
                    onChange={(e) => { setCustSearch(e.target.value); setCustPage(0); }}
                    style={{ marginLeft: "auto", padding: "6px 12px", fontSize: 11, fontFamily: font, border: "1px solid #e8e4de", borderRadius: 4, width: 220, outline: "none" }}
                  />
                  <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
                    <span style={{ fontSize: 10, color: "#6b6860", letterSpacing: "0.06em", textTransform: "uppercase" }}>Sort</span>
                    {(["txns", "spend", "last_seen", "risk"] as const).map((s) => (
                      <button key={s} style={sortPillStyle(custSort === s)} onClick={() => { if (custSort === s) setCustSortDir((d) => d === "desc" ? "asc" : "desc"); else { setCustSort(s); setCustSortDir("desc"); } setCustPage(0); }}>
                        {s === "txns" ? "Txns" : s === "spend" ? "Spend" : s === "last_seen" ? "Last Seen" : "Risk"}{custSort === s ? (custSortDir === "desc" ? " ↓" : " ↑") : ""}
                      </button>
                    ))}
                  </div>
                </div>

                <div style={{ overflowX: "auto" }}>
                  <table style={{ width: "100%", borderCollapse: "collapse", fontFamily: font }}>
                    <thead style={{ background: "#f9f7f4" }}>
                      <tr>
                        <th style={thStyle}>Card ID</th>
                        <th style={thStyle}>Segment</th>
                        <th style={thStyle}>Issuer</th>
                        <th style={thStyle}>Country</th>
                        <th style={thStyle}>Funding</th>
                        <th style={{ ...thStyle, textAlign: "right" }}>Settled</th>
                        <th style={{ ...thStyle, textAlign: "right" }}>Weimi Billed</th>
                        <th style={{ ...thStyle, textAlign: "right" }}>Avg / Visit</th>
                        <th style={{ ...thStyle, textAlign: "right" }}>Gap</th>
                        <th style={thStyle}>First Seen</th>
                        <th style={thStyle}>Last Seen</th>
                        <th style={{ ...thStyle, textAlign: "right" }}>Risk</th>
                      </tr>
                    </thead>
                    <tbody>
                      {pagedCusts.length === 0 && (
                        <tr><td colSpan={12} style={{ ...tdStyle, color: "#6b6860", textAlign: "center", padding: "28px" }}>No customers match the current filter.</td></tr>
                      )}
                      {pagedCusts.map((cp) => {
                        const isSelected = cp.key === selectedCustKey;
                        return (
                          <tr
                            key={cp.key}
                            onClick={() => setSelectedCustKey(isSelected ? null : cp.key)}
                            style={{ background: isSelected ? "rgba(36,84,74,0.07)" : "white", cursor: "pointer", transition: "background .1s" }}
                            onMouseEnter={(e) => { if (!isSelected) (e.currentTarget as HTMLTableRowElement).style.background = "#fafaf8"; }}
                            onMouseLeave={(e) => { (e.currentTarget as HTMLTableRowElement).style.background = isSelected ? "rgba(36,84,74,0.07)" : "white"; }}
                          >
                            <td style={tdStyle}>
                              <span style={{ fontWeight: 700, fontFamily: "monospace", fontSize: 11, color: isSelected ? "#24544a" : "#0a0a0a" }}>{cp.cardDisplay}</span>
                            </td>
                            <td style={tdStyle}>
                              <span style={{ fontSize: 10, fontWeight: 600, padding: "2px 8px", borderRadius: 999, background: `${SEG_COLORS[cp.segment]}18`, color: SEG_COLORS[cp.segment] }}>{cp.segment}</span>
                            </td>
                            <td style={{ ...tdStyle, fontSize: 11 }}>{cp.issuer ?? "—"}</td>
                            <td style={{ ...tdStyle, fontSize: 11 }}>{cp.issuerCountry ?? "—"}</td>
                            <td style={{ ...tdStyle, fontSize: 11, color: "#6b6860" }}>{cp.fundingSource ?? "—"}</td>
                            <td style={{ ...tdStyle, textAlign: "right", fontWeight: 600 }}>{fmtN(cp.settledCount)}</td>
                            <td style={{ ...tdStyle, textAlign: "right", fontWeight: 600, color: "#24544a" }}>{fmtAed(cp.totalSpend)}</td>
                            <td style={{ ...tdStyle, textAlign: "right", color: "#6b6860" }}>{fmtAed(cp.avgSpend)}</td>
                            <td style={{ ...tdStyle, textAlign: "right", color: cp.gap > 0 ? "#DC2626" : "#e8e4de" }}>{cp.gap > 0 ? fmtAed(cp.gap) : "—"}</td>
                            <td style={{ ...tdStyle, color: "#6b6860", fontSize: 11 }}>{dubaiDate(cp.firstSeen)}</td>
                            <td style={{ ...tdStyle, color: "#6b6860", fontSize: 11 }}>{dubaiDate(cp.lastSeen)}</td>
                            <td style={{ ...tdStyle, textAlign: "right" }}>
                              {cp.maxRiskScore > 0 ? (
                                <span style={{ fontSize: 10, fontWeight: 600, color: cp.hasHighRisk ? "#DC2626" : "#6b6860", background: cp.hasHighRisk ? "rgba(220,38,38,0.08)" : "transparent", padding: "2px 6px", borderRadius: 999 }}>
                                  {Math.round(cp.maxRiskScore)}
                                </span>
                              ) : <span style={{ color: "#e8e4de" }}>—</span>}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>

                {/* pagination */}
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 18px", borderTop: "1px solid #e8e4de" }}>
                  <span style={{ fontSize: 11, color: "#6b6860" }}>
                    Page {safeCustPage + 1} of {custPageCount} &middot; {fmtN(filteredCusts.length)} customers
                  </span>
                  <div style={{ display: "flex", gap: 8 }}>
                    <button disabled={safeCustPage === 0} onClick={() => setCustPage((p) => Math.max(0, p - 1))} style={{ padding: "5px 14px", borderRadius: 4, border: "1px solid #e8e4de", background: "#ffffff", color: safeCustPage === 0 ? "#e8e4de" : "#6b6860", cursor: safeCustPage === 0 ? "default" : "pointer", fontFamily: font, fontSize: 11 }}>Prev</button>
                    <button disabled={safeCustPage >= custPageCount - 1} onClick={() => setCustPage((p) => Math.min(custPageCount - 1, p + 1))} style={{ padding: "5px 14px", borderRadius: 4, border: "1px solid #e8e4de", background: "#ffffff", color: safeCustPage >= custPageCount - 1 ? "#e8e4de" : "#6b6860", cursor: safeCustPage >= custPageCount - 1 ? "default" : "pointer", fontFamily: font, fontSize: 11 }}>Next</button>
                  </div>
                </div>
              </div>

              {/* ── Customer Detail Panel ── */}
              {selectedCust && (
                <div style={{ marginTop: 16, background: "white", border: "2px solid #24544a", borderRadius: 8, overflow: "hidden" }}>
                  {/* header */}
                  <div style={{ background: "#0F4D3A", padding: "14px 20px", display: "flex", alignItems: "center", gap: 16 }}>
                    <div>
                      <div style={{ fontSize: 10, color: "#86efac", letterSpacing: "0.12em", textTransform: "uppercase", marginBottom: 2 }}>Customer Detail</div>
                      <div style={{ fontFamily: font, fontWeight: 800, fontSize: 20, color: "white", letterSpacing: "-0.5px" }}>
                        {selectedCust.cardDisplay}
                        {selectedCust.cardBin && <span style={{ fontSize: 12, fontWeight: 400, color: "#86efac", marginLeft: 8 }}>BIN {selectedCust.cardBin}</span>}
                      </div>
                    </div>
                    <div style={{ display: "flex", gap: 10, marginLeft: 24, flexWrap: "wrap" }}>
                      {selectedCust.paymentMethod && <span style={{ fontSize: 11, color: "#cbd5e1", background: "rgba(255,255,255,0.1)", padding: "3px 10px", borderRadius: 999 }}>{selectedCust.paymentMethod}</span>}
                      {selectedCust.fundingSource && <span style={{ fontSize: 11, color: "#cbd5e1", background: "rgba(255,255,255,0.1)", padding: "3px 10px", borderRadius: 999 }}>{selectedCust.fundingSource}</span>}
                      {selectedCust.issuerCountry && <span style={{ fontSize: 11, color: "#cbd5e1", background: "rgba(255,255,255,0.1)", padding: "3px 10px", borderRadius: 999 }}>{selectedCust.issuerCountry}</span>}
                      {selectedCust.isRepeat && <span style={{ fontSize: 11, fontWeight: 700, color: "#fef08a", background: "rgba(217,119,6,0.3)", padding: "3px 10px", borderRadius: 999 }}>REPEAT</span>}
                      {selectedCust.hasHighRisk && <span style={{ fontSize: 11, fontWeight: 700, color: "#fca5a5", background: "rgba(220,38,38,0.25)", padding: "3px 10px", borderRadius: 999 }}>⚠ HIGH RISK</span>}
                    </div>
                    <button
                      onClick={() => setSelectedCustKey(null)}
                      style={{ marginLeft: "auto", padding: "6px 14px", border: "1px solid rgba(255,255,255,0.3)", background: "transparent", color: "white", borderRadius: 4, cursor: "pointer", fontSize: 11, fontFamily: font }}
                    >
                      Close ✕
                    </button>
                  </div>

                  <div style={{ padding: "18px 20px" }}>
                    {/* mini KPIs */}
                    <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: 12, marginBottom: 20 }}>
                      <StatCard label="Settled Txns" value={fmtN(selectedCust.settledCount)} accent="#24544a" valueColor="#24544a" />
                      <StatCard label="Weimi Billed" value={fmtAed(selectedCust.totalSpend)} subtitle="total charged by machine" accent="#24544a" valueColor="#24544a" />
                      <StatCard label="Adyen Captured" value={fmtAed(selectedCapture)} subtitle="actually settled to Boonz" accent="#6366F1" valueColor="#6366F1" />
                      <StatCard label="Capture Gap" value={selectedDetailGap >= 0.01 ? fmtAed(selectedDetailGap) : "AED 0"} subtitle={selectedDetailGap >= 0.01 ? "billed minus captured" : "fully settled ✓"} accent={selectedDetailGap >= 0.01 ? "#DC2626" : "#6b6860"} valueColor={selectedDetailGap >= 0.01 ? "#DC2626" : "#6b6860"} />
                      <StatCard label="Avg per Visit" value={fmtAed(selectedCust.avgSpend)} accent="#8B5CF6" valueColor="#8B5CF6" />
                      <StatCard label="Refused / Cancelled" value={`${fmtN(selectedCust.refusedCount)} / ${fmtN(selectedCust.cancelledCount)}`} subtitle="declined transactions" accent="#e1b460" valueColor="#d97706" />
                    </div>

                    {/* mini charts */}
                    {(custDailyData.length > 0 || custHourData.some((h) => h.txns > 0)) && (
                      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14, marginBottom: 20 }}>
                        {custDailyData.length > 1 && (
                          <div style={{ background: "#f9f7f4", borderRadius: 6, padding: "14px 16px" }}>
                            <h4 style={{ fontFamily: font, fontWeight: 600, fontSize: 12, marginBottom: 10, color: "#0a0a0a" }}>Spend Over Time</h4>
                            <ResponsiveContainer width="100%" height={130}>
                              <LineChart data={custDailyData} margin={{ top: 0, right: 4, bottom: 0, left: -28 }}>
                                <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" vertical={false} />
                                <XAxis dataKey="date" tick={{ fontSize: 8, fontFamily: font, fill: "#6b6860" }} interval="preserveStartEnd" />
                                <YAxis tick={{ fontSize: 8, fontFamily: font, fill: "#6b6860" }} />
                                <Tooltip contentStyle={{ fontFamily: font, fontSize: 10, border: "1px solid #e8e4de", borderRadius: 4 }} formatter={(v: any) => [fmtAed(v), "Spend"]} />
                                <Line type="monotone" dataKey="amount" stroke="#24544a" strokeWidth={2} dot={false} />
                              </LineChart>
                            </ResponsiveContainer>
                          </div>
                        )}
                        <div style={{ background: "#f9f7f4", borderRadius: 6, padding: "14px 16px" }}>
                          <h4 style={{ fontFamily: font, fontWeight: 600, fontSize: 12, marginBottom: 10, color: "#0a0a0a" }}>Hour Pattern (Dubai time)</h4>
                          <ResponsiveContainer width="100%" height={130}>
                            <BarChart data={custHourData} margin={{ top: 0, right: 4, bottom: 0, left: -28 }}>
                              <CartesianGrid strokeDasharray="3 3" stroke="#e8e4de" vertical={false} />
                              <XAxis dataKey="hour" tick={{ fontSize: 8, fontFamily: font, fill: "#6b6860" }} interval={5} />
                              <YAxis tick={{ fontSize: 8, fontFamily: font, fill: "#6b6860" }} allowDecimals={false} />
                              <Tooltip contentStyle={{ fontFamily: font, fontSize: 10, border: "1px solid #e8e4de", borderRadius: 4 }} formatter={(v: any) => [`${v} txns`, "Transactions"]} />
                              <Bar dataKey="txns" fill="#24544a" radius={[2, 2, 0, 0]} />
                            </BarChart>
                          </ResponsiveContainer>
                        </div>
                      </div>
                    )}

                    {/* transactions table */}
                    <h4 style={{ fontFamily: font, fontWeight: 700, fontSize: 13, marginBottom: 10 }}>
                      Transaction History &middot; <span style={{ fontWeight: 400, color: "#6b6860" }}>{fmtN(selectedTxns.length)} records</span>
                    </h4>
                    <div style={{ overflowX: "auto" }}>
                      <table style={{ width: "100%", borderCollapse: "collapse", fontFamily: font }}>
                        <thead style={{ background: "#f9f7f4" }}>
                          <tr>
                            <th style={thStyle}>Date (Dubai)</th>
                            <th style={thStyle}>Store</th>
                            <th style={{ ...thStyle, textAlign: "right" }}>Amount</th>
                            <th style={thStyle}>Status</th>
                            <th style={thStyle}>Method</th>
                            <th style={thStyle}>Funding</th>
                            <th style={{ ...thStyle, textAlign: "right" }}>Risk</th>
                            <th style={thStyle}>PSP Ref</th>
                          </tr>
                        </thead>
                        <tbody>
                          {selectedTxns.slice(0, 200).map((r) => {
                            const isSettled = SETTLED_STATUSES.has(r.status ?? "");
                            const riskScore = r.risk_score ?? 0;
                            return (
                              <tr key={r.adyen_txn_id} style={{ borderBottom: "1px solid #f5f2ee" }}>
                                <td style={tdStyle}>{dubaiDate(r.creation_date)} {dubaiTime(r.creation_date)}</td>
                                <td style={{ ...tdStyle, color: "#6b6860", maxWidth: 180, overflow: "hidden", textOverflow: "ellipsis" }}>{r.store_description ?? "—"}</td>
                                <td style={{ ...tdStyle, textAlign: "right", fontWeight: 600, color: isSettled ? "#24544a" : "#9a948e" }}>{fmtAed(r.captured_amount_value ?? 0)}</td>
                                <td style={tdStyle}>
                                  <span style={{ fontSize: 10, fontWeight: 600, padding: "2px 8px", borderRadius: 999, background: isSettled ? "rgba(36,84,74,0.1)" : r.status === "Refused" ? "rgba(220,38,38,0.08)" : "rgba(107,104,96,0.08)", color: isSettled ? "#24544a" : r.status === "Refused" ? "#DC2626" : "#6b6860" }}>
                                    {r.status ?? "—"}
                                  </span>
                                </td>
                                <td style={{ ...tdStyle, fontSize: 11, color: "#2A3547" }}>{r.payment_method ?? "—"}</td>
                                <td style={{ ...tdStyle, fontSize: 11, color: "#6b6860" }}>{r.funding_source ?? "—"}</td>
                                <td style={{ ...tdStyle, textAlign: "right" }}>
                                  {riskScore > 0 ? (
                                    <span style={{ fontSize: 10, fontWeight: 600, color: riskScore > 50 ? "#DC2626" : "#6b6860", background: riskScore > 50 ? "rgba(220,38,38,0.08)" : "transparent", padding: "2px 6px", borderRadius: 999 }}>
                                      {Math.round(riskScore)}
                                    </span>
                                  ) : <span style={{ color: "#e8e4de" }}>—</span>}
                                </td>
                                <td style={{ ...tdStyle, fontSize: 9, color: "#9a948e", fontFamily: "monospace" }}>{r.psp_reference?.slice(0, 16) ?? "—"}</td>
                              </tr>
                            );
                          })}
                        </tbody>
                      </table>
                    </div>
                    {selectedTxns.length > 200 && (
                      <div style={{ fontSize: 10, color: "#6b6860", padding: "10px 0", textAlign: "center" }}>
                        Showing first 200 of {fmtN(selectedTxns.length)} transactions. Narrow the date range for full history.
                      </div>
                    )}

                    {/* ── Weimi purchases section ── */}
                    {custMerchantRefs.size > 0 && (
                      <div style={{ marginTop: 24 }}>
                        <h4 style={{ fontFamily: font, fontWeight: 700, fontSize: 13, marginBottom: 10 }}>
                          What They Purchased &middot;{" "}
                          <span style={{ fontWeight: 400, color: "#6b6860" }}>
                            {fmtN(custWeimi.length)} Weimi line items matched via merchant reference
                          </span>
                        </h4>

                        {weimiTopProducts.length > 0 && (
                          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14, marginBottom: 16 }}>
                            {/* top products table */}
                            <div style={{ background: "#f9f7f4", borderRadius: 6, padding: "14px 16px" }}>
                              <h5 style={{ fontFamily: font, fontWeight: 600, fontSize: 11, letterSpacing: "0.06em", textTransform: "uppercase", color: "#6b6860", marginBottom: 10 }}>Top Products</h5>
                              <table style={{ width: "100%", borderCollapse: "collapse", fontFamily: font }}>
                                <thead>
                                  <tr>
                                    <th style={{ ...thStyle, background: "transparent", padding: "4px 8px" }}>Product</th>
                                    <th style={{ ...thStyle, background: "transparent", padding: "4px 8px", textAlign: "right" }}>Qty</th>
                                    <th style={{ ...thStyle, background: "transparent", padding: "4px 8px", textAlign: "right" }}>Spend</th>
                                  </tr>
                                </thead>
                                <tbody>
                                  {weimiTopProducts.map((p, i) => (
                                    <tr key={i}>
                                      <td style={{ ...tdStyle, padding: "6px 8px", fontSize: 11 }}>{p.name}</td>
                                      <td style={{ ...tdStyle, padding: "6px 8px", fontSize: 11, textAlign: "right", color: "#6b6860" }}>{fmtN(p.qty)}</td>
                                      <td style={{ ...tdStyle, padding: "6px 8px", fontSize: 11, textAlign: "right", fontWeight: 600, color: "#24544a" }}>{fmtAed(p.spend)}</td>
                                    </tr>
                                  ))}
                                </tbody>
                              </table>
                            </div>

                            {/* product mini bar chart */}
                            <div style={{ background: "#f9f7f4", borderRadius: 6, padding: "14px 16px" }}>
                              <h5 style={{ fontFamily: font, fontWeight: 600, fontSize: 11, letterSpacing: "0.06em", textTransform: "uppercase", color: "#6b6860", marginBottom: 10 }}>By Spend</h5>
                              <ResponsiveContainer width="100%" height={160}>
                                <BarChart data={weimiTopProducts.slice(0, 6)} layout="vertical" margin={{ top: 0, right: 50, bottom: 0, left: 0 }}>
                                  <XAxis type="number" tick={{ fontSize: 8, fontFamily: font, fill: "#6b6860" }} />
                                  <YAxis type="category" dataKey="name" tick={{ fontSize: 9, fontFamily: font, fill: "#6b6860" }} width={80} />
                                  <Tooltip contentStyle={{ fontFamily: font, fontSize: 10, border: "1px solid #e8e4de", borderRadius: 4 }} formatter={(v: any) => [fmtAed(v), "Spend"]} />
                                  <Bar dataKey="spend" fill="#24544a" radius={[0, 3, 3, 0]}>
                                    <LabelList dataKey="spend" position="right" style={{ fontSize: 8, fontFamily: font, fill: "#6b6860" }} formatter={(v: any) => fmtAed(v)} />
                                  </Bar>
                                </BarChart>
                              </ResponsiveContainer>
                            </div>
                          </div>
                        )}

                        {/* full Weimi line items */}
                        <div style={{ overflowX: "auto" }}>
                          <table style={{ width: "100%", borderCollapse: "collapse", fontFamily: font }}>
                            <thead style={{ background: "#f9f7f4" }}>
                              <tr>
                                <th style={thStyle}>Date (Dubai)</th>
                                <th style={thStyle}>Product</th>
                                <th style={thStyle}>Machine</th>
                                <th style={{ ...thStyle, textAlign: "right" }}>Qty</th>
                                <th style={{ ...thStyle, textAlign: "right" }}>Amount</th>
                                <th style={thStyle}>Status</th>
                              </tr>
                            </thead>
                            <tbody>
                              {custWeimi.slice(0, 100).map((s, i) => (
                                <tr key={i} style={{ borderBottom: "1px solid #f5f2ee" }}>
                                  <td style={tdStyle}>{dubaiDate(s.transaction_date)} {dubaiTime(s.transaction_date)}</td>
                                  <td style={{ ...tdStyle, maxWidth: 200, overflow: "hidden", textOverflow: "ellipsis" }}>{s.pod_product_name ?? "—"}</td>
                                  <td style={{ ...tdStyle, fontSize: 11, color: "#6b6860" }}>
                                    {(s.machines as any)?.official_name ?? "—"}
                                  </td>
                                  <td style={{ ...tdStyle, textAlign: "right", fontWeight: 600 }}>{fmtN(s.qty ?? 0)}</td>
                                  <td style={{ ...tdStyle, textAlign: "right", fontWeight: 600, color: "#24544a" }}>{fmtAed(s.total_amount ?? 0)}</td>
                                  <td style={tdStyle}>
                                    <span style={{ fontSize: 10, padding: "2px 8px", borderRadius: 999, background: "rgba(36,84,74,0.1)", color: "#24544a" }}>
                                      {s.delivery_status ?? "—"}
                                    </span>
                                  </td>
                                </tr>
                              ))}
                              {custWeimi.length === 0 && (
                                <tr><td colSpan={6} style={{ ...tdStyle, color: "#6b6860", textAlign: "center", padding: "20px" }}>
                                  No Weimi purchase data matched — this customer&apos;s transactions may be settlement-batch records without merchant reference.
                                </td></tr>
                              )}
                            </tbody>
                          </table>
                        </div>
                      </div>
                    )}
                    {custMerchantRefs.size === 0 && (
                      <div style={{ marginTop: 16, padding: "12px 14px", background: "#f9f7f4", borderRadius: 6, fontSize: 11, color: "#6b6860" }}>
                        <strong>No Weimi purchase data available.</strong> This customer&apos;s Adyen records are settlement-batch type (no merchant_reference). Product history requires the transaction-level Adyen report in n8n.
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>
          );
        })()}

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
                            (a.creation_date ? dubaiDate(a.creation_date) : null) ===
                              (r.transaction_date ? dubaiDate(r.transaction_date) : null),
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
                              {r.transaction_date ? dubaiDate(r.transaction_date) : "—"}
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
