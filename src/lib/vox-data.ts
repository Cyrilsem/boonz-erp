// lib/vox-data.ts
// TypeScript types for VOX Consumer Report data from Supabase
// Source: get_vox_consumer_report(pods, consolidated) RPC function

export interface VoxDailyEntry {
  site: string;
  date: string; // YYYY-MM-DD
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
  date_range: { start: string; end: string };
  mercato: VoxSiteSummary;
  mirdif: VoxSiteSummary;
}

export interface VoxMeta {
  generated_at: string;
  pods_selected: string[];
  consolidated: boolean;
  data_source: string;
  sales_source: string;
  payment_source: string;
}

export interface VoxConsumerReport {
  summary: VoxSummary;
  daily: VoxDailyEntry[];
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

// Pod configuration — maps site names to machine prefixes and display properties
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

// Friendly machine labels for display
export const MACHINE_LABELS: Record<string, string> = {
  "VOXMM-1009-0100-V0": "MRC M1 (VOX)",
  "VOXMM-1013-0101-B0": "MRC M2 (Boonz)",
  "VOXMCC-1009-0201-B0": "MRD M1 (Boonz)",
  "VOXMCC-1011-0101-B0": "MRD M2 (Boonz)",
  "VOXMCC-1012-0100-V0": "MRD M3 (VOX)",
  "VOXMCC-1017-0200-V0": "MRD M4 (VOX)",
};

// Wallet display names
export const WALLET_NAMES: Record<string, string> = {
  visa_applepay: "Apple Pay (Visa)",
  mc_applepay: "Apple Pay (MC)",
  visa_samsungpay: "Samsung Pay (Visa)",
  visa_googlepay: "Google Pay (Visa)",
  mc_googlepay: "Google Pay (MC)",
  mc_samsungpay: "Samsung Pay (MC)",
};

// Color constants
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

// Formatting helpers
export const aed = (v: number) =>
  `AED ${v.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;

export const pct = (v: number, t: number) =>
  t > 0 ? `${((v / t) * 100).toFixed(1)}%` : "0%";

// Fetch function
export async function fetchVoxConsumerReport(
  pods: string[] = ["Mercato", "Mirdif"],
  consolidated: boolean = true,
  startDate?: string | null,
  endDate?: string | null,
): Promise<VoxConsumerReport> {
  const params = new URLSearchParams({
    pods: pods.join(","),
    consolidated: String(consolidated),
  });
  if (startDate) params.set("start_date", startDate);
  if (endDate) params.set("end_date", endDate);
  const res = await fetch(`/api/vox/consumers?${params}`);
  if (!res.ok) throw new Error(`Failed to fetch: ${res.status}`);
  return res.json();
}
