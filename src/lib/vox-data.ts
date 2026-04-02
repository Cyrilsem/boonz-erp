// ── VOX Consumer Report — Types, constants, and fetch helper ─────────────────

export const VOX_PODS = ["Mercato", "Mirdif"] as const;
export type VoxPod = (typeof VOX_PODS)[number];

// ── Summary ───────────────────────────────────────────────────────────────────

export type SiteSummary = {
  total: number;
  txns: number;
  units: number;
  captured: number;
};

export type VoxSummary = {
  total_sales: number;
  total_txns: number;
  total_units: number;
  total_captured: number;
  num_machines: number;
  has_adyen_data: boolean;
  adyen_match_pct: number;
  mercato: SiteSummary;
  mirdif: SiteSummary;
};

// ── Breakdown rows ────────────────────────────────────────────────────────────

export type DailyRow = {
  site: string;
  date: string; // "YYYY-MM-DD"
  amount: number;
};

export type MachineRow = {
  site: string;
  machine: string;
  amount: number;
};

export type ProductRow = {
  site: string;
  name: string;
  revenue: number;
  qty: number;
};

export type HourlyRow = {
  site: string;
  hour: number;
  amount: number;
};

export type DowRow = {
  site: string;
  dow_n: number;
  dow: string;
  amount: number;
};

// ── Payment rows (Adyen-sourced) ──────────────────────────────────────────────

export type FundingRow = {
  site: string;
  source: string;
  count: number;
  sum: number;
};

export type CardRow = {
  site: string;
  method: string;
  count: number;
  sum: number;
};

export type WalletRow = {
  variant: string;
  count: number;
  sum: number;
};

// ── Transaction ledger ────────────────────────────────────────────────────────

export type TxnRow = {
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
};

// ── Meta ──────────────────────────────────────────────────────────────────────

export type VoxMeta = {
  generated_at: string;
  pods_selected: string[];
  consolidated: boolean;
  data_source: string;
  sales_source: string;
  payment_source: string;
};

// ── Full report ───────────────────────────────────────────────────────────────

export type VoxConsumerReport = {
  summary: VoxSummary;
  daily: DailyRow[];
  machines: MachineRow[];
  products: ProductRow[];
  hourly: HourlyRow[];
  dow: DowRow[];
  funding: FundingRow[];
  cards: CardRow[];
  wallets: WalletRow[];
  transactions: TxnRow[];
  meta: VoxMeta;
};

// ── Formatting helpers ────────────────────────────────────────────────────────

export function aed(n: number | null | undefined, decimals = 0): string {
  if (n == null) return "—";
  return `AED ${n.toLocaleString("en-AE", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })}`;
}

export function fmt(n: number | null | undefined): string {
  if (n == null) return "—";
  return n.toLocaleString("en-AE");
}

export function defaultRate(total: number, captured: number): string {
  if (!total || !captured) return "—";
  return `${(((total - captured) / total) * 100).toFixed(1)}%`;
}

export function formatWallet(variant: string): string {
  const map: Record<string, string> = {
    visa_applepay: "Apple Pay (Visa)",
    mc_applepay: "Apple Pay (MC)",
    visa_googlepay: "Google Pay (Visa)",
    mc_googlepay: "Google Pay (MC)",
    visa_samsungpay: "Samsung Pay (V)",
    mc_samsungpay: "Samsung Pay (MC)",
  };
  return map[variant] ?? variant;
}

// ── Fetch ─────────────────────────────────────────────────────────────────────

export async function fetchVoxConsumerReport(
  pods: VoxPod[],
  consolidated: boolean,
): Promise<VoxConsumerReport | null> {
  const params = new URLSearchParams({
    pods: pods.join(","),
    consolidated: String(consolidated),
  });
  try {
    const res = await fetch(`/api/vox/consumers?${params}`, {
      cache: "no-store",
    });
    if (!res.ok) return null;
    return res.json() as Promise<VoxConsumerReport>;
  } catch {
    return null;
  }
}
