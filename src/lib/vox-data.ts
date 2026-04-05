// lib/vox-data.ts

export interface VoxDailyEntry {
  site: string;
  date: string;
  amount: number;
}
export interface VoxWeeklyEntry {
  site: string;
  week_start: string;
  week_label: string;
  amount: number;
}
export interface VoxMachineEntry {
  site: string;
  machine: string;
  amount: number;
}
export interface VoxProductEntry {
  site: string;
  name: string;
  revenue: number;
  qty: number;
}
export interface VoxHourlyEntry {
  site: string;
  hour: number;
  amount: number;
}
export interface VoxDowEntry {
  site: string;
  dow_n: number;
  dow: string;
  amount: number;
}
export interface VoxFundingEntry {
  site: string;
  source: string;
  count: number;
  sum: number;
}
export interface VoxCardEntry {
  site: string;
  method: string;
  count: number;
  sum: number;
}
export interface VoxWalletEntry {
  variant: string;
  count: number;
  sum: number;
}
export interface VoxTransaction {
  date: string;
  time: string;
  machine: string;
  site: string;
  psp: string;
  funding: string;
  card: string;
  wallet: string;
  total: number;
  captured: number;
  units: number;
  items: string;
  disc: boolean;
}
export interface VoxSiteSummary {
  total: number;
  txns: number;
  units: number;
  captured: number;
}
export interface VoxSummary {
  total_sales: number;
  total_txns: number;
  total_units: number;
  total_captured: number;
  num_machines: number;
  has_adyen_data: boolean;
  adyen_match_pct: number;
  date_from: string;
  date_to: string;
  matched_txns: number;
  unmatched_txns: number;
  matched_total: number;
  matched_captured: number;
  default_rate: number;
  default_gap: number;
  disc_count: number;
  adyen_txn_count: number;
  total_paid: number;
  mercato: VoxSiteSummary;
  mirdif: VoxSiteSummary;
}
export interface VoxMeta {
  generated_at: string;
  pods_selected: string[];
  consolidated: boolean;
  date_from: string;
  date_to: string;
  data_source: string;
}
export interface VoxConsumerReport {
  summary: VoxSummary;
  daily: VoxDailyEntry[];
  weekly: VoxWeeklyEntry[];
  machines: VoxMachineEntry[];
  products: VoxProductEntry[];
  hourly: VoxHourlyEntry[];
  dow: VoxDowEntry[];
  funding: VoxFundingEntry[];
  cards: VoxCardEntry[];
  wallets: VoxWalletEntry[];
  transactions: VoxTransaction[];
  meta: VoxMeta;
}

export const VOX_PODS: Record<
  string,
  { machines: string[]; color: string; label: string; inception: string }
> = {
  Mercato: {
    machines: ["VOXMM-1009-0100-V0", "VOXMM-1013-0101-B0"],
    color: "#3B82F6",
    label: "VOXMM",
    inception: "06 Feb 2026",
  },
  Mirdif: {
    machines: [
      "VOXMCC-1009-0201-B0",
      "VOXMCC-1011-0101-B0",
      "VOXMCC-1012-0100-V0",
      "VOXMCC-1017-0200-V0",
    ],
    color: "#10B981",
    label: "VOXMCC",
    inception: "19 Mar 2026",
  },
};
export const MACHINE_LABELS: Record<string, string> = {
  "VOXMM-1009-0100-V0": "MRC M1 (VOX)",
  "VOXMM-1013-0101-B0": "MRC M2 (Boonz)",
  "VOXMCC-1009-0201-B0": "MRD M1 (Boonz)",
  "VOXMCC-1011-0101-B0": "MRD M2 (Boonz)",
  "VOXMCC-1012-0100-V0": "MRD M3 (VOX)",
  "VOXMCC-1017-0200-V0": "MRD M4 (VOX)",
};
export const WALLET_NAMES: Record<string, string> = {
  visa_applepay: "Apple Pay (Visa)",
  mc_applepay: "Apple Pay (MC)",
  visa_samsungpay: "Samsung Pay (Visa)",
  visa_googlepay: "Google Pay (Visa)",
  mc_googlepay: "Google Pay (MC)",
  mc_samsungpay: "Samsung Pay (MC)",
};
export const FUND_COLORS: Record<string, string> = {
  DEBIT: "#3B82F6",
  CREDIT: "#10B981",
  PREPAID: "#F59E0B",
};
export const CARD_COLORS: Record<string, string> = {
  Visa: "#1D4ED8",
  Mastercard: "#DC2626",
};
export const PROD_COLORS = [
  "#3B82F6",
  "#10B981",
  "#F59E0B",
  "#EF4444",
  "#8B5CF6",
  "#EC4899",
  "#14B8A6",
  "#F97316",
  "#6366F1",
  "#84CC16",
  "#06B6D4",
  "#D946EF",
];

export const aed = (v: number) =>
  `AED ${v.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
export const pct = (v: number, t: number) =>
  t > 0 ? `${((v / t) * 100).toFixed(1)}%` : "0%";

export interface VoxCommercialReport {
  params: {
    date_from: string;
    date_to: string;
    pods: string[];
    adyen_fixed_fee: number;
    adyen_pct_fee: number;
    boonz_share_pct: number;
    vox_share_pct: number;
  };
  waterfall: {
    total_amount: number;
    default_amount: number;
    captured_amount: number;
    refund_amount: number;
    adyen_fees: number;
    net_revenue: number;
    boonz_share: number;
    vox_share: number;
    boonz_cogs: number;
    vox_net_dues: number;
    boonz_receipts: number;
    txn_count: number;
    units_sold: number;
    matched_txns: number;
    unmatched_txns: number;
    disc_count: number;
    default_rate_pct: number;
    adyen_fee_pct: number;
    cogs_ratio_pct: number;
  };
  by_site: Array<{
    site: string;
    total_amount: number;
    captured_amount: number;
    default_amount: number;
    adyen_fees: number;
    net_revenue: number;
    boonz_share: number;
    vox_share: number;
    boonz_cogs: number;
    vox_net_dues: number;
    txns: number;
    units: number;
  }>;
  transactions: Array<{
    txn_base: string;
    txn_date: string;
    site: string;
    machine: string;
    items: string;
    units: number;
    total_amount: number;
    captured_amount: number;
    default_amount: number;
    refunded_amount: number;
    adyen_fees: number;
    net_revenue: number;
    boonz_share: number;
    vox_share: number;
    boonz_cogs: number;
    vox_net_dues: number;
    matched_adyen: boolean;
    psp_reference: string | null;
    has_unknown_cost: boolean;
  }>;
  discrepancies: Array<{
    psp: string;
    date: string;
    site: string;
    machine: string;
    items: string;
    total: number;
    captured: number;
    gap: number;
  }>;
}

export async function fetchVoxCommercialReport(
  pods: string[] = ["Mercato", "Mirdif"],
  dateFrom: string = "2026-02-06",
  dateTo: string = new Date().toISOString().split("T")[0],
): Promise<VoxCommercialReport> {
  const params = new URLSearchParams({
    pods: pods.join(","),
    date_from: dateFrom,
    date_to: dateTo,
  });
  const res = await fetch(`/api/vox/commercial?${params}`);
  if (!res.ok) throw new Error(`Failed to fetch commercial: ${res.status}`);
  return res.json();
}

export async function fetchVoxConsumerReport(
  pods: string[] = ["Mercato", "Mirdif"],
  consolidated: boolean = true,
  dateFrom: string = "2026-02-06",
  dateTo: string = new Date().toISOString().split("T")[0],
): Promise<VoxConsumerReport> {
  const params = new URLSearchParams({
    pods: pods.join(","),
    consolidated: String(consolidated),
    date_from: dateFrom,
    date_to: dateTo,
  });
  const res = await fetch(`/api/vox/consumers?${params}`);
  if (!res.ok) throw new Error(`Failed to fetch: ${res.status}`);
  return res.json();
}
