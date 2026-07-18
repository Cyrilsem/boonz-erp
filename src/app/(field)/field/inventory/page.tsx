"use client";

import {
  useEffect,
  useState,
  useCallback,
  useMemo,
  useRef,
  Dispatch,
  SetStateAction,
} from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { adjustWarehouseLineMetadata } from "@/lib/inventory/adjust-warehouse-line";
import {
  attemptCorrection,
  attemptStatusChange,
  correlationId,
} from "@/lib/inventory/attempt-rpcs";
import { useInventorySession } from "@/lib/inventory/session";
import { FieldHeader } from "../../components/field-header";
import { getExpiryStyle } from "@/app/(field)/utils/expiry";
import { usePageTour } from "../../components/onboarding/use-page-tour";
import Tour from "../../components/onboarding/tour";
import PendingRemoveApprovalsPanel from "@/components/inventory/PendingRemoveApprovalsPanel";
import { StartInventorySessionBar } from "@/components/inventory/StartInventorySessionBar";
import { CanaryIndicator } from "@/components/inventory/CanaryIndicator";

// Phase G P1 B.1/B.2: only these roles can save edits via the wrappers.
const EDIT_ROLES = new Set([
  "warehouse",
  "operator_admin",
  "superadmin",
  "manager",
]);

// Phase G P1 B.6: WH-tab to warehouse_id mapping (matches operator console).
const WAREHOUSE_ID_BY_TAB: Record<string, string | null> = {
  all: null,
  WH_CENTRAL: "4bebef68-9e36-4a5c-9c2c-142f8dbdae85",
  WH_MM: "0aef9ccf-32ad-4545-8413-29bebd931d0b",
  WH_MCC: "4fcfb52c-271f-4aa7-a373-3495e3271cd3",
};

interface InventoryRow {
  wh_inventory_id: string;
  boonz_product_id: string;
  boonz_product_name: string;
  product_category: string | null;
  batch_id: string;
  wh_location: string | null;
  warehouse_stock: number;
  expiration_date: string | null;
  status: string;
  warehouse_id: string | null;
  warehouse_name: string;
}

type WarehouseFilter = "all" | "WH_CENTRAL" | "WH_MM" | "WH_MCC";

interface ControlEdit {
  qty: number;
  location: string;
  status: string;
}

type ExpiryFilter = "all" | "expired" | "3days" | "7days" | "30days";
type SortOption = "expiry" | "location" | "name" | "qty_high" | "qty_low";
type StatusFilter = "All" | "Active" | "Expired" | "Inactive";
type GroupBy = "category" | "product" | "location" | "none";

// ─── Pending review types ──────────────────────────────────────────────────────

const REVIEWER_ROLES = [
  "warehouse",
  "operator_admin",
  "manager",
  "superadmin",
] as const;

interface PendingEdit {
  edit_id: string;
  pod_inventory_id: string;
  machine_id: string;
  boonz_product_id: string;
  edit_type:
    | "sold"
    | "partial_sold"
    | "damaged"
    | "expired"
    | "in_stock"
    | "return_to_warehouse"
    | "transfer";
  destination_machine_id: string | null;
  destination_machine_name: string | null;
  quantity_update: number | null;
  notes: string | null;
  created_at: string;
  machine_name: string;
  boonz_product_name: string;
  submitted_by_name: string | null;
  current_pod_stock: number | null;
  pod_product_id: string | null;
}

function formatTimeAgo(dateStr: string): string {
  const diffMs = Date.now() - new Date(dateStr).getTime();
  const mins = Math.floor(diffMs / 60000);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

interface InventoryGroup {
  key: string;
  items: InventoryRow[];
  totalUnits: number;
}

interface BatchRow {
  wh_inventory_id: string;
  warehouse_stock: number;
  expiration_date: string | null;
  status: string;
  wh_location: string | null;
  batch_id: string;
}

interface ProductGroup {
  boonz_product_id: string;
  boonz_product_name: string;
  product_category: string | null;
  batches: BatchRow[];
  totalStock: number;
  earliestExpiry: string | null;
}

type SaveFeedback = {
  qty?: "saved" | "error";
  location?: "saved" | "error";
};

// RC-02 (Batch 2, PRD-100): a WH qty edit is no longer a bare absolute
// overwrite. The user must pick a disposition: count correction (with reason),
// refill to machine (deep-links the capture flow), or write-off.
interface DispositionState {
  id: string; // wh_inventory_id
  oldQty: number;
  newQty: number;
  productId: string;
  productName: string;
  warehouseId: string;
  expirationDate: string | null;
}

const expiryFilters: { label: string; value: ExpiryFilter }[] = [
  { label: "All", value: "all" },
  { label: "Expired", value: "expired" },
  { label: "<=3 days", value: "3days" },
  { label: "<=7 days", value: "7days" },
  { label: "<=30 days", value: "30days" },
];

function daysUntilExpiry(date: string | null): number | null {
  if (!date) return null;
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const exp = new Date(date + "T00:00:00");
  return Math.ceil((exp.getTime() - today.getTime()) / (1000 * 60 * 60 * 24));
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return "\u2014";
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

/** Format YYYY-MM-DD as "12 Jul 26" */
function formatExpiryBatch(dateStr: string): string {
  return new Date(dateStr + "T00:00:00").toLocaleDateString("en-GB", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
}

function ExpiryBadge({ expiryDate }: { expiryDate: string | null }) {
  const style = getExpiryStyle(expiryDate);
  if (!style.label) return null;
  return (
    <span
      className={`rounded-full ${style.badgeBg} px-2 py-0.5 text-xs font-medium ${style.badgeText}`}
    >
      {style.label}
    </span>
  );
}

function DaysBadge({ expiryDate }: { expiryDate: string | null }) {
  if (!expiryDate) {
    return (
      <span className="shrink-0 rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400">
        No expiry
      </span>
    );
  }
  const days = daysUntilExpiry(expiryDate);
  if (days === null) return null;
  if (days <= 0) {
    return (
      <span className="shrink-0 rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-900 dark:text-red-300">
        Expired
      </span>
    );
  }
  const cls =
    days <= 7
      ? "text-red-600 dark:text-red-400"
      : days <= 30
        ? "text-amber-600 dark:text-amber-400"
        : "text-green-600 dark:text-green-400";
  return (
    <span className={`shrink-0 text-xs font-medium ${cls}`}>{days}d left</span>
  );
}

function SectionHeader({
  label,
  itemCount,
  countLabel,
  totalUnits,
}: {
  label: string;
  itemCount: number;
  countLabel: string;
  totalUnits: number;
}) {
  return (
    <div className="flex items-center gap-2 mt-4 mb-2">
      <span className="shrink-0 text-sm font-semibold text-neutral-700 dark:text-neutral-300">
        {label}
      </span>
      <span className="shrink-0 text-xs text-neutral-500">
        {itemCount} {countLabel} · {totalUnits} units
      </span>
      <hr className="flex-1 border-neutral-200 dark:border-neutral-700" />
    </div>
  );
}

// ─── ProductCard component ─────────────────────────────────────────────────

interface ProductCardProps {
  pg: ProductGroup;
  isCollapsed: boolean;
  onToggleCollapse: () => void;
  controlMode: boolean;
  controlEdits: Map<string, ControlEdit>;
  updateControlEdit: (
    id: string,
    field: keyof ControlEdit,
    value: string | number,
  ) => void;
  inlineQtys: Record<string, number>;
  inlineLocations: Record<string, string>;
  saveFeedback: Record<string, SaveFeedback>;
  setInlineQtys: Dispatch<SetStateAction<Record<string, number>>>;
  setInlineLocations: Dispatch<SetStateAction<Record<string, string>>>;
  onSaveQty: (id: string, qty: number) => Promise<void>;
  onSaveLocation: (id: string, location: string) => Promise<void>;
  onToggleStatus: (id: string, currentStatus: string) => Promise<void>;
  /** Phase G P1: when false, inline qty / location / status edits are locked. */
  canEdit: boolean;
}

function ProductCard({
  pg,
  isCollapsed,
  onToggleCollapse,
  controlMode,
  controlEdits,
  updateControlEdit,
  inlineQtys,
  inlineLocations,
  saveFeedback,
  setInlineQtys,
  setInlineLocations,
  onSaveQty,
  onSaveLocation,
  onToggleStatus,
  canEdit,
}: ProductCardProps) {
  return (
    <div className="overflow-hidden rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
      {/* Card header */}
      <button
        onClick={onToggleCollapse}
        className="flex w-full items-center gap-3 px-4 py-3 text-left hover:bg-neutral-50 dark:hover:bg-neutral-900"
      >
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-bold">{pg.boonz_product_name}</p>
          {pg.product_category && (
            <p className="text-xs text-neutral-500">{pg.product_category}</p>
          )}
        </div>
        <span className="shrink-0 text-sm font-bold text-neutral-700 dark:text-neutral-300">
          {pg.totalStock} units
        </span>
        {isCollapsed && pg.earliestExpiry && (
          <span className="shrink-0 text-xs text-neutral-500">
            {formatExpiryBatch(pg.earliestExpiry)}
          </span>
        )}
        <span className="shrink-0 text-xs text-neutral-400">
          {isCollapsed ? "▶" : "▼"}
        </span>
      </button>

      {/* Batch rows */}
      {!isCollapsed && (
        <div className="border-t border-neutral-100 dark:border-neutral-800">
          {pg.batches.map((batch) => {
            const edit = controlEdits.get(batch.wh_inventory_id);
            const batchQty =
              controlMode && edit
                ? edit.qty
                : (inlineQtys[batch.wh_inventory_id] ?? batch.warehouse_stock);
            const batchLocation =
              controlMode && edit
                ? edit.location
                : (inlineLocations[batch.wh_inventory_id] ??
                  batch.wh_location ??
                  "");
            const fb = saveFeedback[batch.wh_inventory_id];
            return (
              <div
                key={batch.wh_inventory_id}
                className="flex flex-wrap items-center gap-2 border-b border-neutral-50 px-4 py-2.5 last:border-b-0 dark:border-neutral-800/50"
              >
                {/* Expiry date */}
                <span className="w-20 shrink-0 text-xs text-neutral-600 dark:text-neutral-400">
                  {batch.expiration_date
                    ? formatExpiryBatch(batch.expiration_date)
                    : "—"}
                </span>
                {/* Days badge */}
                <DaysBadge expiryDate={batch.expiration_date} />
                {/* Low-stock badge — F-04 */}
                {batch.warehouse_stock <= 5 && batch.warehouse_stock > 0 && (
                  <span className="shrink-0 rounded-full bg-orange-100 px-2 py-0.5 text-xs font-medium text-orange-700 dark:bg-orange-900 dark:text-orange-300">
                    Low stock
                  </span>
                )}
                {/* Qty input */}
                <div className="flex items-center gap-1">
                  <input
                    type="number"
                    min={0}
                    value={batchQty}
                    disabled={!canEdit && !controlMode}
                    onChange={(e) => {
                      const val = parseInt(e.target.value, 10) || 0;
                      if (controlMode) {
                        updateControlEdit(batch.wh_inventory_id, "qty", val);
                      } else {
                        setInlineQtys((prev) => ({
                          ...prev,
                          [batch.wh_inventory_id]: Math.max(0, val),
                        }));
                      }
                    }}
                    onBlur={(e) => {
                      if (!controlMode) {
                        void onSaveQty(
                          batch.wh_inventory_id,
                          parseInt(e.target.value, 10) || 0,
                        );
                      }
                    }}
                    className="w-16 rounded border border-neutral-300 px-2 py-1 text-center text-sm disabled:bg-neutral-100 disabled:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900 dark:disabled:bg-neutral-800"
                  />
                  {fb?.qty && (
                    <span
                      className={`text-xs ${fb.qty === "saved" ? "text-green-600 dark:text-green-400" : "text-red-500 dark:text-red-400"}`}
                    >
                      {fb.qty === "saved" ? "✓" : "✗"}
                    </span>
                  )}
                </div>
                {/* Location input */}
                <div className="flex min-w-0 flex-1 items-center gap-1">
                  <input
                    type="text"
                    value={batchLocation}
                    placeholder="Unassigned"
                    disabled={!canEdit && !controlMode}
                    onChange={(e) => {
                      if (controlMode) {
                        updateControlEdit(
                          batch.wh_inventory_id,
                          "location",
                          e.target.value,
                        );
                      } else {
                        setInlineLocations((prev) => ({
                          ...prev,
                          [batch.wh_inventory_id]: e.target.value,
                        }));
                      }
                    }}
                    onBlur={(e) => {
                      if (!controlMode) {
                        void onSaveLocation(
                          batch.wh_inventory_id,
                          e.target.value,
                        );
                      }
                    }}
                    className="w-full min-w-0 rounded border border-neutral-200 px-2 py-1 text-xs placeholder:text-neutral-400 disabled:bg-neutral-100 disabled:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:disabled:bg-neutral-800"
                  />
                  {fb?.location && (
                    <span
                      className={`shrink-0 text-xs ${fb.location === "saved" ? "text-green-600 dark:text-green-400" : "text-red-500 dark:text-red-400"}`}
                    >
                      {fb.location === "saved" ? "✓" : "✗"}
                    </span>
                  )}
                </div>
                {/* Status pill */}
                <button
                  disabled={!canEdit && !controlMode}
                  onClick={() => {
                    if (!controlMode) {
                      void onToggleStatus(batch.wh_inventory_id, batch.status);
                    } else if (edit) {
                      updateControlEdit(
                        batch.wh_inventory_id,
                        "status",
                        edit.status === "Active" ? "Inactive" : "Active",
                      );
                    }
                  }}
                  className={`shrink-0 rounded-full px-2.5 py-0.5 text-xs font-medium disabled:opacity-60 disabled:cursor-not-allowed ${
                    batch.status === "Active"
                      ? "bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300"
                      : batch.status === "Expired"
                        ? "cursor-default bg-red-100 text-red-700 dark:bg-red-900 dark:text-red-300"
                        : "bg-neutral-200 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400"
                  }`}
                >
                  {controlMode && edit ? edit.status : batch.status}
                </button>
                {/* Link to detail page */}
                <Link
                  href={`/field/inventory/${batch.wh_inventory_id}`}
                  className="shrink-0 text-xs text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
                  onClick={(e) => e.stopPropagation()}
                >
                  →
                </Link>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

export default function InventoryPage() {
  const [rows, setRows] = useState<InventoryRow[]>([]);
  const [loading, setLoading] = useState(true);
  const { showTour, tourSteps, completeTour } = usePageTour("inventory");
  const [search, setSearch] = useState("");
  const [expiryFilter, setExpiryFilter] = useState<ExpiryFilter>("7days");
  const [sortBy, setSortBy] = useState<SortOption>("expiry");
  const [hideEmpty, setHideEmpty] = useState(true);
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("Active");
  const [groupBy, setGroupBy] = useState<GroupBy>("none");
  const [warehouseFilter, setWarehouseFilter] =
    useState<WarehouseFilter>("all");

  /** Products collapsed to header-only (default: all expanded) */
  const [collapsedProducts, setCollapsedProducts] = useState<Set<string>>(
    new Set(),
  );
  /** Per-batch qty values for inline edits (normal mode) */
  const [inlineQtys, setInlineQtys] = useState<Record<string, number>>({});
  /** Per-batch location values for inline edits (normal mode) */
  const [inlineLocations, setInlineLocations] = useState<
    Record<string, string>
  >({});
  /** Per-batch save feedback ("✓ Saved" / "✗ Error") */
  const [saveFeedback, setSaveFeedback] = useState<
    Record<string, SaveFeedback>
  >({});

  // RC-02: disposition chooser state for inline qty edits.
  const router = useRouter();
  const [disposition, setDisposition] = useState<DispositionState | null>(null);
  const [dispositionReason, setDispositionReason] = useState("");
  const [dispositionSaving, setDispositionSaving] = useState(false);
  const [dispositionError, setDispositionError] = useState<string | null>(null);

  // Pending reviews
  const [userRole, setUserRole] = useState<string | null>(null);
  // PRD-001: track manual tab/dropdown change so the role-aware default below
  // does not clobber a deliberate pick made before user role resolves.
  const tabHasBeenUserChanged = useRef(false);
  const [pendingEdits, setPendingEdits] = useState<PendingEdit[]>([]);
  const [reviewExpanded, setReviewExpanded] = useState(true);
  const [processingIds, setProcessingIds] = useState<Set<string>>(new Set());
  const [reviewToast, setReviewToast] = useState<string | null>(null);

  // Inventory control mode
  const [controlMode, setControlMode] = useState(false);
  const [controlEdits, setControlEdits] = useState<Map<string, ControlEdit>>(
    new Map(),
  );
  const [controlSaving, setControlSaving] = useState(false);
  const [controlMessage, setControlMessage] = useState<string | null>(null);

  // Phase G P1: inventory-control session context. All inline qty / location /
  // status writes require an open session AND a role in EDIT_ROLES.
  const { session } = useInventorySession();
  const canEdit = Boolean(session && userRole && EDIT_ROLES.has(userRole));

  const fetchData = useCallback(async () => {
    const supabase = createClient();

    const query = supabase.from("warehouse_inventory").select(`
        wh_inventory_id,
        boonz_product_id,
        batch_id,
        wh_location,
        warehouse_stock,
        expiration_date,
        status,
        warehouse_id,
        boonz_products!inner(boonz_product_name, product_category),
        warehouses(name)
      `);

    const { data } = await query;

    if (!data || data.length === 0) {
      setRows([]);
      setLoading(false);
      return;
    }

    const mapped: InventoryRow[] = data.map((row) => {
      const p = row.boonz_products as unknown as {
        boonz_product_name: string;
        product_category: string | null;
      };
      const w = row.warehouses as unknown as { name: string } | null;
      return {
        wh_inventory_id: row.wh_inventory_id,
        boonz_product_id: row.boonz_product_id,
        boonz_product_name: p.boonz_product_name,
        product_category: p.product_category,
        batch_id: row.batch_id ?? "",
        wh_location: row.wh_location,
        warehouse_stock: row.warehouse_stock ?? 0,
        expiration_date: row.expiration_date,
        status: row.status ?? "Active",
        warehouse_id: row.warehouse_id ?? null,
        warehouse_name: w?.name ?? "WH_CENTRAL",
      };
    });

    setRows(mapped);
    setLoading(false);
  }, []);

  const fetchUserRole = useCallback(async () => {
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) return;
    const { data } = await supabase
      .from("user_profiles")
      .select("role")
      .eq("id", user.id)
      .single();
    const role = (data?.role as string | undefined) ?? null;
    setUserRole(role);
    // PRD-001 change 1: warehouse-role users default to WH_CENTRAL so the
    // Start Inventory Control button is visible without a tab/dropdown
    // discovery. Other roles keep "all".
    if (role === "warehouse" && !tabHasBeenUserChanged.current) {
      setWarehouseFilter("WH_CENTRAL");
    }
  }, []);

  const fetchPendingEdits = useCallback(async () => {
    const supabase = createClient();
    const { data } = await supabase
      .from("pod_inventory_edits")
      .select(
        `
        edit_id, pod_inventory_id, machine_id, boonz_product_id, pod_product_id,
        edit_type, quantity_update, notes, status, created_at, requested_by,
        destination_machine_id,
        machines!pod_inventory_edits_machine_id_fkey(official_name),
        boonz_products!inner(boonz_product_name),
        pod_inventory(current_stock),
        destination_machine:machines!pod_inventory_edits_destination_machine_id_fkey(official_name)
      `,
      )
      .eq("status", "pending")
      .order("created_at", { ascending: true });

    if (!data || data.length === 0) {
      setPendingEdits([]);
      return;
    }

    const userIds = [
      ...new Set(
        data
          .map((r) => r.requested_by as string | null)
          .filter((id): id is string => id !== null),
      ),
    ];
    const { data: profiles } = await supabase
      .from("user_profiles")
      .select("id, full_name")
      .in("id", userIds);
    const nameMap = new Map<string, string | null>(
      (profiles ?? []).map((p) => [
        p.id as string,
        p.full_name as string | null,
      ]),
    );

    setPendingEdits(
      data.map((r) => {
        const m = r.machines as unknown as { official_name: string } | null;
        const bp = r.boonz_products as unknown as {
          boonz_product_name: string;
        } | null;
        const reqBy = r.requested_by as string | null;
        return {
          edit_id: r.edit_id,
          pod_inventory_id: r.pod_inventory_id,
          machine_id: r.machine_id,
          boonz_product_id: r.boonz_product_id,
          edit_type: r.edit_type as
            | "sold"
            | "partial_sold"
            | "damaged"
            | "expired"
            | "in_stock"
            | "return_to_warehouse"
            | "transfer",
          quantity_update: r.quantity_update as number | null,
          notes: r.notes as string | null,
          created_at: r.created_at as string,
          machine_name: m?.official_name ?? "",
          boonz_product_name: bp?.boonz_product_name ?? "",
          submitted_by_name: reqBy ? (nameMap.get(reqBy) ?? null) : null,
          current_pod_stock:
            (r.pod_inventory as unknown as { current_stock: number } | null)
              ?.current_stock ?? null,
          destination_machine_id:
            (r.destination_machine_id as string | null) ?? null,
          destination_machine_name:
            (
              r.destination_machine as unknown as {
                official_name: string;
              } | null
            )?.official_name ?? null,
          pod_product_id: (r.pod_product_id as string | null) ?? null,
        };
      }),
    );
  }, []);

  useEffect(() => {
    fetchData();
    fetchUserRole();
    fetchPendingEdits();
  }, [fetchData, fetchUserRole, fetchPendingEdits]);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        fetchData();
        fetchPendingEdits();
      }
    }
    function handleFocus() {
      fetchData();
      fetchPendingEdits();
    }
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("focus", handleFocus);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("focus", handleFocus);
    };
  }, [fetchData, fetchPendingEdits]);

  // Initialise inline edit values whenever rows reload
  useEffect(() => {
    const qtys: Record<string, number> = {};
    const locs: Record<string, string> = {};
    for (const row of rows) {
      qtys[row.wh_inventory_id] = row.warehouse_stock;
      locs[row.wh_inventory_id] = row.wh_location ?? "";
    }
    setInlineQtys(qtys);
    setInlineLocations(locs);
  }, [rows]);

  // PRD-001 Change 3: loud-fail helper. Used by every silent-return edit path
  // (inline qty, status toggle, bulk-save) so a no-session attempt is
  // unmistakable on mobile and the bar scrolls back into view if the keyboard
  // had hidden it.
  function alertNoSession() {
    if (typeof window !== "undefined") {
      window.alert(
        "Inventory edits are locked. Tap 'Start Inventory Control' at the top of the page first.",
      );
    }
    document.getElementById("start-inventory-session-bar")?.scrollIntoView({
      behavior: "smooth",
      block: "start",
    });
  }

  // PRD-001 Change 4: re-verify session against the DB before flipping into
  // bulk-edit mode. The localStorage-backed `canEdit` can flicker truthy from
  // a stale session_id, which would let the user enter bulk mode without a
  // real open session and then silently fail every save.
  async function handleEnterBulkEdit() {
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) {
      alertNoSession();
      return;
    }
    const { data, error } = await supabase
      .from("inventory_control_session")
      .select("session_id")
      .eq("started_by", user.id)
      .eq("status", "open")
      .limit(1)
      .maybeSingle();
    if (error || !data?.session_id) {
      alertNoSession();
      return;
    }
    enterControlMode();
  }

  // Enter control mode: initialize edits from current rows
  function enterControlMode() {
    const edits = new Map<string, ControlEdit>();
    for (const row of rows) {
      edits.set(row.wh_inventory_id, {
        qty: row.warehouse_stock,
        location: row.wh_location ?? "",
        status: row.status,
      });
    }
    setControlEdits(edits);
    setControlMode(true);
  }

  function updateControlEdit(
    id: string,
    field: keyof ControlEdit,
    value: string | number,
  ) {
    setControlEdits((prev) => {
      const next = new Map(prev);
      const existing = next.get(id);
      if (existing) {
        next.set(id, { ...existing, [field]: value });
      }
      return next;
    });
  }

  async function completeControl() {
    if (!canEdit || !session) {
      // PRD-001 Change 3: the 3-second message was easy to miss on mobile.
      alertNoSession();
      return;
    }
    setControlSaving(true);
    const supabase = createClient();

    const {
      data: { user },
    } = await supabase.auth.getUser();
    const userId = user?.id;

    for (const row of rows) {
      const edit = controlEdits.get(row.wh_inventory_id);
      if (!edit) continue;

      const qtyChanged = edit.qty !== row.warehouse_stock;
      const locationChanged =
        (edit.location || null) !== (row.wh_location || null);
      const statusChanged = edit.status !== row.status;

      if (!qtyChanged && !locationChanged && !statusChanged) continue;
      if (!row.warehouse_id) continue;

      // Phase G P1: split the legacy single-call into per-dimension wrappers
      // so each mutation lands in inventory_control_attempt with the right
      // field_changed. apply_inventory_correction auto-reactivates Inactive
      // when new_stock > 0, so we track the effective status as we go and
      // skip a redundant status flip when the qty edit already did it.
      let effectiveStock = row.warehouse_stock;
      let effectiveStatus = row.status;

      if (qtyChanged) {
        const r = await attemptCorrection(supabase, {
          sessionId: session.session_id,
          whInventoryId: row.wh_inventory_id,
          newWarehouseStock: edit.qty,
          reason: "inventory_control",
          correlationId: correlationId(),
        });
        if (r.result === "success") {
          effectiveStock = edit.qty;
          if (effectiveStatus === "Inactive" && effectiveStock > 0) {
            effectiveStatus = "Active";
          }
        }
      }

      if (
        statusChanged &&
        edit.status !== effectiveStatus &&
        (edit.status === "Active" || edit.status === "Inactive")
      ) {
        const r = await attemptStatusChange(supabase, {
          sessionId: session.session_id,
          whInventoryId: row.wh_inventory_id,
          newStatus: edit.status,
          reason: "inventory_control",
          correlationId: correlationId(),
          newWarehouseStock:
            edit.status === "Active" ? effectiveStock : undefined,
        });
        if (r.result === "success") {
          effectiveStatus = edit.status;
        }
      }

      if (locationChanged) {
        await adjustWarehouseLineMetadata(supabase, {
          warehouseId: row.warehouse_id,
          line: {
            wh_inventory_id: row.wh_inventory_id,
            boonz_product_id: row.boonz_product_id,
            expiration_date: row.expiration_date,
            wh_location: edit.location || null,
          },
          currentWarehouseStock: effectiveStock,
          currentStatus: effectiveStatus,
          reason: "inventory_control",
        });
      }
    }

    // Insert inventory control log
    if (userId) {
      await supabase.from("inventory_control_log").insert({
        conducted_by: userId,
        notes: null,
      });
    }

    setControlMode(false);
    setControlEdits(new Map());
    setControlSaving(false);
    setControlMessage("Inventory control logged");
    await fetchData();

    setTimeout(() => setControlMessage(null), 3000);
  }

  // ─── Review handlers ────────────────────────────────────────────────────────

  function showReviewToast(msg: string) {
    setReviewToast(msg);
    setTimeout(() => setReviewToast(null), 3000);
  }

  async function handleApprove(editId: string, edit: PendingEdit) {
    setProcessingIds((prev) => new Set([...prev, editId]));
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    // PRD-013 P1.C: route through canonical RPC. All per-edit_type dispatch
    // (expired / sold / partial_sold / return_to_warehouse / add_new_product)
    // happens server-side in approve_pod_inventory_edit. Atomic flip of the
    // edit row + pod_inventory + warehouse_inventory in one txn.
    const { error } = await supabase.rpc("approve_pod_inventory_edit", {
      p_edit_id: editId,
      p_approver_id: user?.id ?? null,
      p_decision_note: null,
    });
    if (error) {
      alert(`Approve failed: ${error.message}`);
      setProcessingIds((prev) => {
        const s = new Set(prev);
        s.delete(editId);
        return s;
      });
      return;
    }
    setPendingEdits((prev) => prev.filter((e) => e.edit_id !== editId));
    setProcessingIds((prev) => {
      const s = new Set(prev);
      s.delete(editId);
      return s;
    });
    showReviewToast(`Approved ${edit.edit_type}`);
    return;
  }

  async function handleReject(editId: string) {
    // PRD-013 P1.D: route through canonical reject RPC; requires decision note
    // >= 10 chars. Prompt the operator for the note (no toast lib; same
    // alert/prompt fallback used by PRD-001 / PRD-012).
    const note =
      typeof window !== "undefined"
        ? window.prompt("Reject reason (>= 10 chars):", "")
        : "";
    const trimmed = (note ?? "").trim();
    if (trimmed.length < 10) {
      alert(
        `Reject requires a decision note of at least 10 characters (got ${trimmed.length}).`,
      );
      return;
    }
    setProcessingIds((prev) => new Set([...prev, editId]));
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { error } = await supabase.rpc("reject_pod_inventory_edit", {
      p_edit_id: editId,
      p_decision_note: trimmed,
      p_approver_id: user?.id ?? null,
    });
    if (error) {
      alert(`Reject failed: ${error.message}`);
      setProcessingIds((prev) => {
        const s = new Set(prev);
        s.delete(editId);
        return s;
      });
      return;
    }
    setPendingEdits((prev) => prev.filter((e) => e.edit_id !== editId));
    setProcessingIds((prev) => {
      const s = new Set(prev);
      s.delete(editId);
      return s;
    });
    showReviewToast("Edit rejected");
  }

  // ─── Inline save helpers ────────────────────────────────────────────────────

  function clearFeedbackField(id: string, field: keyof SaveFeedback) {
    setTimeout(() => {
      setSaveFeedback((prev) => {
        if (!prev[id]) return prev;
        const updated: SaveFeedback = { ...prev[id] };
        delete updated[field];
        return { ...prev, [id]: updated };
      });
    }, 1500);
  }

  // RC-02 (Batch 2, PRD-100): the inline qty box no longer performs a bare
  // absolute overwrite on blur. It now opens a disposition chooser — the
  // warehouse user must say WHY the number changed: (a) count correction with
  // a reason (>= 10 chars, still via attempt_inventory_correction, which now
  // stamps honest manual_adjust provenance after backend M1/M2), (b) refill to
  // machine (deep-links /field/capture prefilled -> record_actual_refill), or
  // (c) write-off (warehouse_expire_writeoff for a full batch; partial
  // write-offs go through count-correction with a mandatory 'write-off:'
  // prefix — there is no partial write-off RPC yet).
  async function saveInlineQty(id: string, qty: number) {
    const safeQty = Math.max(0, qty);
    const row = rows.find((r) => r.wh_inventory_id === id);
    if (!row || !row.warehouse_id) {
      setSaveFeedback((prev) => ({
        ...prev,
        [id]: { ...prev[id], qty: "error" as const },
      }));
      clearFeedbackField(id, "qty");
      return;
    }
    // Unchanged value -> no write, no modal (previously every blur fired an
    // attempt_inventory_correction even when nothing changed).
    if (safeQty === row.warehouse_stock) return;
    // Phase G P1: stock writes must flow through attempt_inventory_correction
    // so the session captures the attempt (success or failure).
    if (!canEdit || !session) {
      setSaveFeedback((prev) => ({
        ...prev,
        [id]: { ...prev[id], qty: "error" as const },
      }));
      clearFeedbackField(id, "qty");
      // PRD-001 Change 3: alertNoSession() also scrolls the bar back into view
      // if the soft keyboard pushed it off-screen.
      alertNoSession();
      return;
    }
    setDispositionReason("");
    setDispositionError(null);
    setDisposition({
      id,
      oldQty: row.warehouse_stock,
      newQty: safeQty,
      productId: row.boonz_product_id,
      productName: row.boonz_product_name,
      warehouseId: row.warehouse_id,
      expirationDate: row.expiration_date,
    });
  }

  /** Close the chooser without writing; revert the inline value. */
  function cancelDisposition() {
    if (!disposition) return;
    setInlineQtys((prev) => ({
      ...prev,
      [disposition.id]: disposition.oldQty,
    }));
    setDisposition(null);
  }

  /** Shared post-write bookkeeping for the disposition paths. */
  function finishDisposition(ok: boolean, appliedQty: number) {
    if (!disposition) return;
    const { id, oldQty } = disposition;
    setSaveFeedback((prev) => ({
      ...prev,
      [id]: { ...prev[id], qty: ok ? "saved" : "error" },
    }));
    if (ok) {
      setRows((prev) =>
        prev.map((r) =>
          r.wh_inventory_id === id ? { ...r, warehouse_stock: appliedQty } : r,
        ),
      );
    } else {
      setInlineQtys((prev) => ({ ...prev, [id]: oldQty }));
    }
    clearFeedbackField(id, "qty");
    setDispositionSaving(false);
    setDisposition(null);
  }

  /** Disposition (a): count correction — reason required, >= 10 chars. */
  async function applyCountCorrection() {
    if (!disposition || !session) return;
    const reason = dispositionReason.trim();
    if (reason.length < 10) {
      setDispositionError(
        `Count correction needs a reason of at least 10 characters (got ${reason.length}).`,
      );
      return;
    }
    setDispositionSaving(true);
    const supabase = createClient();
    const result = await attemptCorrection(supabase, {
      sessionId: session.session_id,
      whInventoryId: disposition.id,
      newWarehouseStock: disposition.newQty,
      reason: `inline_qty_edit: ${reason}`,
      correlationId: correlationId(),
    });
    finishDisposition(result.result === "success", disposition.newQty);
  }

  /** Disposition (c): write-off (expired/damaged). Full batch (new qty 0)
   *  routes through warehouse_expire_writeoff (zeroes the row, audit-logged,
   *  inactivation stays propose-then-confirm). Partial write-offs fall back to
   *  attempt_inventory_correction with a mandatory 'write-off:' reason prefix
   *  — no partial write-off RPC exists yet (gap noted in FE_CHANGES). */
  async function applyWriteOff() {
    if (!disposition || !session) return;
    const reason = dispositionReason.trim();
    if (reason.length < 10) {
      setDispositionError(
        `Write-off needs a reason of at least 10 characters (got ${reason.length}).`,
      );
      return;
    }
    setDispositionSaving(true);
    const supabase = createClient();
    if (disposition.newQty === 0) {
      const {
        data: { user },
      } = await supabase.auth.getUser();
      // Live signature (verified): warehouse_expire_writeoff(
      //   p_wh_inventory_id uuid, p_reason text, p_caller_id uuid) -> jsonb
      const { data, error } = await supabase.rpc("warehouse_expire_writeoff", {
        p_wh_inventory_id: disposition.id,
        p_reason: `write-off: ${reason}`,
        p_caller_id: user?.id ?? null,
      });
      const status = (data as { status?: string } | null)?.status;
      const ok =
        !error && (status === "written_off" || status === "already_done");
      if (!ok && error) setDispositionError(error.message);
      finishDisposition(ok, 0);
      return;
    }
    const result = await attemptCorrection(supabase, {
      sessionId: session.session_id,
      whInventoryId: disposition.id,
      newWarehouseStock: disposition.newQty,
      reason: `write-off: ${reason}`,
      correlationId: correlationId(),
    });
    finishDisposition(result.result === "success", disposition.newQty);
  }

  /** Disposition (b): the qty drop was really a refill — nothing is written
   *  here. Revert the inline value (record_actual_refill will do the WH
   *  decrement itself) and deep-link the capture flow prefilled. */
  function goToRefillCapture() {
    if (!disposition) return;
    const delta = disposition.oldQty - disposition.newQty;
    setInlineQtys((prev) => ({
      ...prev,
      [disposition.id]: disposition.oldQty,
    }));
    const params = new URLSearchParams({
      product: disposition.productId,
      warehouse: disposition.warehouseId,
      qty: String(delta),
    });
    if (disposition.expirationDate) {
      params.set("expiry", disposition.expirationDate);
    }
    setDisposition(null);
    router.push(`/field/capture?${params.toString()}`);
  }

  async function saveInlineLocation(id: string, location: string) {
    const supabase = createClient();
    const row = rows.find((r) => r.wh_inventory_id === id);
    if (!row || !row.warehouse_id) {
      setSaveFeedback((prev) => ({
        ...prev,
        [id]: { ...prev[id], location: "error" as const },
      }));
      clearFeedbackField(id, "location");
      return;
    }
    if (!canEdit) {
      setSaveFeedback((prev) => ({
        ...prev,
        [id]: { ...prev[id], location: "error" as const },
      }));
      clearFeedbackField(id, "location");
      return;
    }
    const normalisedLocation = location.trim() || null;
    // Phase G P1: wh_location is metadata-only — routed through the
    // metadata-only canonical writer; never through the qty/status wrappers.
    const result = await adjustWarehouseLineMetadata(supabase, {
      warehouseId: row.warehouse_id,
      line: {
        wh_inventory_id: id,
        boonz_product_id: row.boonz_product_id,
        expiration_date: row.expiration_date,
        wh_location: normalisedLocation,
      },
      currentWarehouseStock: row.warehouse_stock,
      currentStatus: row.status,
      reason: "inline_location_edit",
    });

    const ok = result.ok;
    setSaveFeedback((prev) => ({
      ...prev,
      [id]: { ...prev[id], location: ok ? "saved" : "error" },
    }));
    if (ok) {
      setRows((prev) =>
        prev.map((r) =>
          r.wh_inventory_id === id
            ? { ...r, wh_location: normalisedLocation }
            : r,
        ),
      );
    }
    clearFeedbackField(id, "location");
  }

  async function toggleBatchStatus(id: string, currentStatus: string) {
    if (currentStatus === "Expired") return;
    if (!canEdit || !session) {
      // PRD-001 Change 3: previously a silent return left the user with no
      // feedback when tapping a status pill without a session.
      alertNoSession();
      return;
    }
    const newStatus: "Active" | "Inactive" =
      currentStatus === "Active" ? "Inactive" : "Active";
    const row = rows.find((r) => r.wh_inventory_id === id);
    if (!row || !row.warehouse_id) return;

    // Phase G P1: status flips route through attempt_status_change so
    // both Active->Inactive (inactivate_warehouse_row) and Inactive->Active
    // (reactivate_warehouse_row) land in inventory_control_attempt.
    const supabase = createClient();
    const result = await attemptStatusChange(supabase, {
      sessionId: session.session_id,
      whInventoryId: id,
      newStatus,
      reason: "toggle_batch_status",
      correlationId: correlationId(),
      newWarehouseStock:
        newStatus === "Active" ? row.warehouse_stock : undefined,
    });

    if (result.result === "success") {
      setRows((prev) =>
        prev.map((r) =>
          r.wh_inventory_id === id ? { ...r, status: newStatus } : r,
        ),
      );
    }
  }

  function toggleCollapse(boonzProductId: string) {
    setCollapsedProducts((prev) => {
      const next = new Set(prev);
      if (next.has(boonzProductId)) {
        next.delete(boonzProductId);
      } else {
        next.add(boonzProductId);
      }
      return next;
    });
  }

  const processed: InventoryRow[] = useMemo(() => {
    let filtered = rows;

    // Warehouse filter
    if (warehouseFilter !== "all") {
      filtered = filtered.filter((r) => r.warehouse_name === warehouseFilter);
    }

    // Status filter — when an expiry filter is active, also surface Inactive /
    // Expired rows that fall within the expiry window so they don't silently
    // disappear behind the default "Active" status pill.
    if (statusFilter !== "All") {
      filtered = filtered.filter((r) => {
        if (r.status === statusFilter) return true;
        if (
          expiryFilter !== "all" &&
          (r.status === "Inactive" || r.status === "Expired")
        ) {
          const days = daysUntilExpiry(r.expiration_date);
          if (days === null)
            return expiryFilter === "expired" && r.status === "Expired";
          switch (expiryFilter) {
            case "expired":
              return days <= 0;
            case "3days":
              return days <= 3;
            case "7days":
              return days <= 7;
            case "30days":
              return days <= 30;
          }
        }
        return false;
      });
    }

    // Hide empty
    if (hideEmpty) {
      filtered = filtered.filter((r) => r.warehouse_stock > 0);
    }

    // Search filter
    if (search.trim()) {
      const q = search.toLowerCase();
      filtered = filtered.filter((r) =>
        r.boonz_product_name.toLowerCase().includes(q),
      );
    }

    // Expiry filter
    filtered = filtered.filter((r) => {
      if (expiryFilter === "all") return true;
      const days = daysUntilExpiry(r.expiration_date);
      if (days === null) return false;
      switch (expiryFilter) {
        case "expired":
          return days <= 0;
        case "3days":
          return days <= 3;
        case "7days":
          return days <= 7;
        case "30days":
          return days <= 30;
      }
    });

    // Sort
    filtered = [...filtered].sort((a, b) => {
      switch (sortBy) {
        case "expiry": {
          const da = daysUntilExpiry(a.expiration_date);
          const db = daysUntilExpiry(b.expiration_date);
          if (da === null && db === null) return 0;
          if (da === null) return 1;
          if (db === null) return -1;
          return da - db;
        }
        case "location": {
          const la = a.wh_location ?? "";
          const lb = b.wh_location ?? "";
          return la.localeCompare(lb);
        }
        case "name":
          return a.boonz_product_name.localeCompare(b.boonz_product_name);
        case "qty_high":
          return b.warehouse_stock - a.warehouse_stock;
        case "qty_low":
          return a.warehouse_stock - b.warehouse_stock;
      }
    });

    return filtered;
  }, [
    rows,
    search,
    expiryFilter,
    sortBy,
    hideEmpty,
    statusFilter,
    warehouseFilter,
  ]);

  const groups: InventoryGroup[] = useMemo(() => {
    if (groupBy === "none") return [];

    const map = new Map<string, InventoryRow[]>();
    for (const row of processed) {
      let key: string;
      if (groupBy === "category") key = row.product_category ?? "Uncategorised";
      else if (groupBy === "product") key = row.boonz_product_name;
      else key = row.wh_location ?? "No location";

      const existing = map.get(key);
      if (existing) existing.push(row);
      else map.set(key, [row]);
    }

    const result: InventoryGroup[] = Array.from(map.entries()).map(
      ([key, items]) => ({
        key,
        items,
        totalUnits: items.reduce((s, r) => s + r.warehouse_stock, 0),
      }),
    );

    // Sort groups: location → alpha; category/product → totalUnits DESC
    if (groupBy === "location") {
      result.sort((a, b) => a.key.localeCompare(b.key));
    } else {
      result.sort((a, b) => b.totalUnits - a.totalUnits);
    }

    // Sort items within each group
    for (const group of result) {
      group.items.sort((a, b) => {
        const da = daysUntilExpiry(a.expiration_date);
        const db = daysUntilExpiry(b.expiration_date);
        const secondaryA =
          groupBy === "product" ? (a.wh_location ?? "") : a.boonz_product_name;
        const secondaryB =
          groupBy === "product" ? (b.wh_location ?? "") : b.boonz_product_name;
        if (da === null && db === null)
          return secondaryA.localeCompare(secondaryB);
        if (da === null) return 1;
        if (db === null) return -1;
        const diff = da - db;
        return diff !== 0 ? diff : secondaryA.localeCompare(secondaryB);
      });
    }

    return result;
  }, [processed, groupBy]);

  /** Batch rows grouped by product, sorted for the current sortBy */
  const productGroups: ProductGroup[] = useMemo(() => {
    const map = new Map<string, ProductGroup>();
    const order: string[] = [];

    for (const row of processed) {
      if (!map.has(row.boonz_product_id)) {
        order.push(row.boonz_product_id);
        map.set(row.boonz_product_id, {
          boonz_product_id: row.boonz_product_id,
          boonz_product_name: row.boonz_product_name,
          product_category: row.product_category,
          batches: [],
          totalStock: 0,
          earliestExpiry: null,
        });
      }
      const pg = map.get(row.boonz_product_id)!;
      pg.batches.push({
        wh_inventory_id: row.wh_inventory_id,
        warehouse_stock: row.warehouse_stock,
        expiration_date: row.expiration_date,
        status: row.status,
        wh_location: row.wh_location,
        batch_id: row.batch_id,
      });
      pg.totalStock += row.warehouse_stock;
      if (
        row.expiration_date &&
        (!pg.earliestExpiry || row.expiration_date < pg.earliestExpiry)
      ) {
        pg.earliestExpiry = row.expiration_date;
      }
    }

    // Sort batches within each product by expiry ASC NULLS LAST
    for (const pg of map.values()) {
      pg.batches.sort((a, b) => {
        if (!a.expiration_date && !b.expiration_date) return 0;
        if (!a.expiration_date) return 1;
        if (!b.expiration_date) return -1;
        return a.expiration_date.localeCompare(b.expiration_date);
      });
    }

    // Build result in first-occurrence order (inherits row-level sort from `processed`)
    let result = order.map((id) => map.get(id)!);

    // For qty sorts, re-sort products by total stock after grouping
    if (sortBy === "qty_high") {
      result = [...result].sort((a, b) => b.totalStock - a.totalStock);
    } else if (sortBy === "qty_low") {
      result = [...result].sort((a, b) => a.totalStock - b.totalStock);
    }

    return result;
  }, [processed, sortBy]);

  /** ProductGroups sectioned for category/location groupBy views */
  const sectionGroups: {
    key: string;
    productGroups: ProductGroup[];
    totalUnits: number;
  }[] = useMemo(() => {
    if (groupBy === "none" || groupBy === "product") return [];

    const map = new Map<string, ProductGroup[]>();
    for (const pg of productGroups) {
      const key =
        groupBy === "category"
          ? (pg.product_category ?? "Uncategorised")
          : (pg.batches[0]?.wh_location ?? "No location");
      if (!map.has(key)) map.set(key, []);
      map.get(key)!.push(pg);
    }

    const sections = Array.from(map.entries()).map(([key, pgs]) => ({
      key,
      productGroups: pgs,
      totalUnits: pgs.reduce((s, pg) => s + pg.totalStock, 0),
    }));

    if (groupBy === "location") {
      sections.sort((a, b) => a.key.localeCompare(b.key));
    } else {
      sections.sort((a, b) => b.totalUnits - a.totalUnits);
    }
    return sections;
  }, [productGroups, groupBy]);

  if (loading) {
    return (
      <>
        <FieldHeader title="Inventory" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading inventory...</p>
        </div>
      </>
    );
  }

  // F-05: CSV export of the currently filtered + sorted `processed` array.
  function exportCSV() {
    const headers = [
      "Product Name",
      "Category",
      "Batch ID",
      "Location",
      "Stock",
      "Expiry Date",
      "Status",
    ];
    const csvRows = [
      headers.join(","),
      ...processed.map((r) =>
        [
          `"${r.boonz_product_name.replace(/"/g, '""')}"`,
          `"${(r.product_category ?? "").replace(/"/g, '""')}"`,
          r.batch_id,
          `"${(r.wh_location ?? "").replace(/"/g, '""')}"`,
          r.warehouse_stock,
          r.expiration_date ?? "",
          r.status,
        ].join(","),
      ),
    ];
    const blob = new Blob([csvRows.join("\n")], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `warehouse-inventory-${getDubaiDate()}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Inventory"
        rightAction={
          !controlMode ? (
            <div className="flex items-center gap-2">
              <button
                onClick={exportCSV}
                className="rounded-lg border border-neutral-200 px-3 py-1.5 text-xs text-neutral-600 hover:bg-neutral-50 dark:border-neutral-700 dark:text-neutral-400 dark:hover:bg-neutral-800"
              >
                Export CSV
              </button>
              <button
                onClick={handleEnterBulkEdit}
                disabled={!canEdit}
                className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50"
                title={
                  !canEdit
                    ? "Tap Start Inventory Control at the top to begin"
                    : undefined
                }
              >
                + Bulk Edit
              </button>
            </div>
          ) : (
            <button
              onClick={() => {
                setControlMode(false);
                setControlEdits(new Map());
              }}
              className="rounded-lg bg-neutral-200 px-3 py-1.5 text-xs font-medium text-neutral-700 hover:bg-neutral-300 dark:bg-neutral-700 dark:text-neutral-200 dark:hover:bg-neutral-600"
            >
              Cancel
            </button>
          )
        }
      />

      {showTour && tourSteps.length > 0 && (
        <Tour
          steps={tourSteps}
          onComplete={completeTour}
          onSkip={completeTour}
        />
      )}
      <div className="px-4 py-4">
        {/* PRD-001 Change 2: sticky so the bar stays under the page header
            when the user scrolls or the soft keyboard pushes the viewport up. */}
        <div className="sticky top-[var(--field-header-height,56px)] z-30 -mx-4 px-4 mb-3 space-y-2 bg-white/95 backdrop-blur dark:bg-neutral-950/95 pb-2 border-b border-neutral-100 dark:border-neutral-800">
          <StartInventorySessionBar
            warehouseId={WAREHOUSE_ID_BY_TAB[warehouseFilter] ?? null}
            warehouseLabel={
              warehouseFilter === "all" ? "select a warehouse" : warehouseFilter
            }
            role={userRole}
            onSelectWarehouse={(key) => {
              tabHasBeenUserChanged.current = true;
              setWarehouseFilter(key);
            }}
          />
          <CanaryIndicator />
        </div>

        {/* BUG-010: Returns awaiting WH-side approval (driver_confirm_remove → wh_approve_remove_receipt) */}
        <PendingRemoveApprovalsPanel />

        {/* Control mode message */}
        {controlMessage && (
          <div className="mb-3 rounded-lg bg-green-100 px-3 py-2 text-sm font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
            {controlMessage}
          </div>
        )}

        {/* ── Pending Reviews section ── */}
        {userRole &&
          (REVIEWER_ROLES as readonly string[]).includes(userRole) &&
          pendingEdits.length > 0 && (
            <div className="mb-4">
              <button
                onClick={() => setReviewExpanded((e) => !e)}
                className="flex w-full items-center gap-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-left dark:border-amber-900/40 dark:bg-amber-950/30"
              >
                <span className="text-sm font-semibold text-amber-900 dark:text-amber-300">
                  Pending Reviews
                </span>
                <span className="rounded-full bg-amber-500 px-2 py-0.5 text-xs font-bold text-white">
                  {pendingEdits.length}
                </span>
                <span className="ml-auto text-xs text-amber-600 dark:text-amber-400">
                  {reviewExpanded ? "▲" : "▼"}
                </span>
              </button>

              {reviewExpanded && (
                <ul className="mt-2 space-y-2">
                  {pendingEdits.map((edit) => {
                    const isProcessing = processingIds.has(edit.edit_id);
                    const badge =
                      edit.edit_type === "sold"
                        ? {
                            label: "Sold",
                            cls: "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300",
                          }
                        : edit.edit_type === "partial_sold"
                          ? {
                              label: "Partial sold",
                              cls: "bg-orange-100 text-orange-700 dark:bg-orange-900 dark:text-orange-300",
                            }
                          : edit.edit_type === "damaged"
                            ? {
                                label: "Damaged",
                                cls: "bg-red-100 text-red-700 dark:bg-red-900 dark:text-red-300",
                              }
                            : edit.edit_type === "expired"
                              ? {
                                  label: "Removed (expired)",
                                  cls: "bg-neutral-200 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400",
                                }
                              : edit.edit_type === "return_to_warehouse"
                                ? {
                                    label: "Return to WH",
                                    cls: "bg-purple-100 text-purple-700 dark:bg-purple-900 dark:text-purple-300",
                                  }
                                : edit.edit_type === "transfer"
                                  ? {
                                      label: "↔ Transfer",
                                      cls: "bg-teal-100 text-teal-700 dark:bg-teal-900 dark:text-teal-300",
                                    }
                                  : {
                                      label: "Stock update",
                                      cls: "bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400",
                                    };

                    return (
                      <li
                        key={edit.edit_id}
                        className="flex items-start gap-3 rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
                      >
                        <div className="min-w-0 flex-1">
                          <p className="text-sm font-bold">
                            {edit.boonz_product_name}
                          </p>
                          <p className="text-xs text-neutral-500">
                            {edit.machine_name}
                          </p>
                          <div className="mt-1 flex flex-wrap items-center gap-1.5">
                            <span
                              className={`rounded-full px-2 py-0.5 text-xs font-medium ${badge.cls}`}
                            >
                              {badge.label}
                            </span>
                            {edit.edit_type === "transfer" ? (
                              <span className="text-xs text-neutral-500">
                                {edit.quantity_update} units &middot;{" "}
                                {edit.machine_name} &rarr;{" "}
                                {edit.destination_machine_name ?? "Unknown"}
                              </span>
                            ) : edit.edit_type === "in_stock" &&
                              edit.quantity_update !== null ? (
                              <span className="text-xs text-neutral-500">
                                Pod stock: {edit.current_pod_stock ?? "?"}{" "}
                                &rarr; {edit.quantity_update} (
                                {edit.current_pod_stock !== null
                                  ? (() => {
                                      const d =
                                        edit.quantity_update -
                                        edit.current_pod_stock!;
                                      return d >= 0 ? `+${d}` : `${d}`;
                                    })()
                                  : "Δ?"}
                                )
                              </span>
                            ) : edit.quantity_update !== null ? (
                              <span className="text-xs text-neutral-500">
                                Qty: {edit.quantity_update}
                              </span>
                            ) : null}
                          </div>
                          {edit.notes && (
                            <p className="mt-1 text-xs italic text-neutral-400">
                              {edit.notes}
                            </p>
                          )}
                          <p className="mt-1 text-xs text-neutral-400">
                            {edit.submitted_by_name ?? "Driver"} ·{" "}
                            {formatTimeAgo(edit.created_at)}
                          </p>
                        </div>
                        <div className="flex shrink-0 flex-col gap-1.5">
                          <button
                            onClick={() => handleApprove(edit.edit_id, edit)}
                            disabled={isProcessing}
                            className="rounded-lg bg-green-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-green-700 disabled:opacity-40"
                          >
                            ✓ Approve
                          </button>
                          <button
                            onClick={() => handleReject(edit.edit_id)}
                            disabled={isProcessing}
                            className="rounded-lg border border-red-400 px-3 py-1.5 text-xs font-semibold text-red-600 hover:bg-red-50 disabled:opacity-40 dark:border-red-700 dark:text-red-400 dark:hover:bg-red-950/30"
                          >
                            ✗ Reject
                          </button>
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}
            </div>
          )}

        {/* Search */}
        <div data-tour="inventory-filters">
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search products..."
            className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
          />

          {/* Warehouse filter */}
          <div className="mb-3 flex items-center gap-2">
            <select
              value={warehouseFilter}
              onChange={(e) => {
                tabHasBeenUserChanged.current = true;
                setWarehouseFilter(e.target.value as WarehouseFilter);
              }}
              className="rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            >
              <option value="all">All Warehouses</option>
              <option value="WH_CENTRAL">Central</option>
              <option value="WH_MCC">MCC</option>
              <option value="WH_MM">MM</option>
            </select>
          </div>

          {/* Status filter pills */}
          <div className="mb-3 flex gap-2">
            {[
              { label: "All", value: "All" as StatusFilter },
              { label: "Active", value: "Active" as StatusFilter },
              { label: "Expired", value: "Expired" as StatusFilter },
              { label: "Inactive", value: "Inactive" as StatusFilter },
            ].map((s) => (
              <button
                key={s.value}
                onClick={() => setStatusFilter(s.value)}
                className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                  statusFilter === s.value
                    ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                    : "bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700"
                }`}
              >
                {s.label}
              </button>
            ))}
          </div>

          {/* Expiry filter pills */}
          <div className="mb-3 flex gap-2 overflow-x-auto pb-1">
            {expiryFilters.map((f) => (
              <button
                key={f.value}
                onClick={() => setExpiryFilter(f.value)}
                className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                  expiryFilter === f.value
                    ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                    : "bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700"
                }`}
              >
                {f.label}
              </button>
            ))}
          </div>

          {/* Hide empty toggle */}
          <div className="mb-3 flex gap-2">
            <button
              onClick={() => setHideEmpty(true)}
              className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                hideEmpty
                  ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                  : "bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700"
              }`}
            >
              Hide empty
            </button>
            <button
              onClick={() => setHideEmpty(false)}
              className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                !hideEmpty
                  ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                  : "bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700"
              }`}
            >
              Show all
            </button>
          </div>

          {/* Sort */}
          <div className="mb-3 flex items-center gap-2 text-xs text-neutral-500">
            <span>Sort:</span>
            {[
              { label: "Expiry", value: "expiry" as SortOption },
              { label: "Location", value: "location" as SortOption },
              { label: "Name", value: "name" as SortOption },
              { label: "Qty High", value: "qty_high" as SortOption },
              { label: "Qty Low", value: "qty_low" as SortOption },
            ].map((s) => (
              <button
                key={s.value}
                onClick={() => setSortBy(s.value)}
                className={`rounded px-2 py-1 transition-colors ${
                  sortBy === s.value
                    ? "bg-neutral-200 font-medium text-neutral-900 dark:bg-neutral-700 dark:text-neutral-100"
                    : "hover:bg-neutral-100 dark:hover:bg-neutral-800"
                }`}
              >
                {s.label}
              </button>
            ))}
          </div>

          {/* Group by */}
          <div className="mb-4 flex items-center gap-2 text-xs text-neutral-500">
            <span>Group:</span>
            {[
              { label: "Category", value: "category" as GroupBy },
              { label: "Product", value: "product" as GroupBy },
              { label: "Location", value: "location" as GroupBy },
              { label: "None", value: "none" as GroupBy },
            ].map((g) => (
              <button
                key={g.value}
                onClick={() => setGroupBy(g.value)}
                className={`rounded px-2 py-1 transition-colors ${
                  groupBy === g.value
                    ? "bg-neutral-200 font-medium text-neutral-900 dark:bg-neutral-700 dark:text-neutral-100"
                    : "hover:bg-neutral-100 dark:hover:bg-neutral-800"
                }`}
              >
                {g.label}
              </button>
            ))}
          </div>
        </div>

        {/* Results */}
        <div data-tour="inventory-list">
          {productGroups.length === 0 ? (
            <div className="flex flex-col items-center justify-center p-8 text-center">
              <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
                No items match this filter
              </p>
              <p className="mt-1 text-sm text-neutral-500">
                {search
                  ? "Try a different search term"
                  : "Try a different expiry range"}
              </p>
            </div>
          ) : groupBy !== "none" && groupBy !== "product" ? (
            /* ── Sectioned product-card view (category / location groupBy) ── */
            <div>
              {sectionGroups.map((section) => (
                <div key={section.key}>
                  <SectionHeader
                    label={section.key}
                    itemCount={section.productGroups.length}
                    countLabel="products"
                    totalUnits={section.totalUnits}
                  />
                  <div className="space-y-3">
                    {section.productGroups.map((pg) => (
                      <ProductCard
                        key={pg.boonz_product_id}
                        pg={pg}
                        isCollapsed={collapsedProducts.has(pg.boonz_product_id)}
                        onToggleCollapse={() =>
                          toggleCollapse(pg.boonz_product_id)
                        }
                        controlMode={controlMode}
                        controlEdits={controlEdits}
                        updateControlEdit={updateControlEdit}
                        inlineQtys={inlineQtys}
                        inlineLocations={inlineLocations}
                        saveFeedback={saveFeedback}
                        setInlineQtys={setInlineQtys}
                        setInlineLocations={setInlineLocations}
                        onSaveQty={saveInlineQty}
                        onSaveLocation={saveInlineLocation}
                        onToggleStatus={toggleBatchStatus}
                        canEdit={canEdit}
                      />
                    ))}
                  </div>
                </div>
              ))}
            </div>
          ) : (
            /* ── Flat product cards ── */
            <div className="space-y-3">
              {productGroups.map((pg) => (
                <ProductCard
                  key={pg.boonz_product_id}
                  pg={pg}
                  isCollapsed={collapsedProducts.has(pg.boonz_product_id)}
                  onToggleCollapse={() => toggleCollapse(pg.boonz_product_id)}
                  controlMode={controlMode}
                  controlEdits={controlEdits}
                  updateControlEdit={updateControlEdit}
                  inlineQtys={inlineQtys}
                  inlineLocations={inlineLocations}
                  saveFeedback={saveFeedback}
                  setInlineQtys={setInlineQtys}
                  setInlineLocations={setInlineLocations}
                  onSaveQty={saveInlineQty}
                  onSaveLocation={saveInlineLocation}
                  onToggleStatus={toggleBatchStatus}
                  canEdit={canEdit}
                />
              ))}
            </div>
          )}
        </div>
      </div>

      {/* RC-02: disposition chooser for inline qty edits. No default — the
          user must pick what the change IS. Keyboard path for the common case
          (count correction): type qty, blur, type reason, Enter. Esc cancels. */}
      {disposition && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-4 sm:items-center">
          <div className="w-full max-w-md rounded-2xl bg-white p-4 shadow-xl dark:bg-neutral-900">
            <p className="text-sm font-bold">{disposition.productName}</p>
            <p className="mt-0.5 text-xs text-neutral-500">
              {disposition.oldQty} → {disposition.newQty} (
              {disposition.newQty - disposition.oldQty > 0 ? "+" : ""}
              {disposition.newQty - disposition.oldQty} units)
              {disposition.expirationDate
                ? ` · exp ${formatExpiryBatch(disposition.expirationDate)}`
                : ""}
            </p>
            <p className="mt-2 text-xs text-neutral-600 dark:text-neutral-400">
              What is this change? Nothing is saved until you choose.
            </p>

            <input
              type="text"
              autoFocus
              value={dispositionReason}
              onChange={(e) => {
                setDispositionReason(e.target.value);
                setDispositionError(null);
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !dispositionSaving) {
                  void applyCountCorrection();
                } else if (e.key === "Escape") {
                  cancelDisposition();
                }
              }}
              placeholder="Reason (min 10 chars) — required for correction / write-off"
              className="mt-2 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-950"
            />
            {dispositionError && (
              <p className="mt-1 text-xs text-red-600 dark:text-red-400">
                {dispositionError}
              </p>
            )}

            <div className="mt-3 flex flex-col gap-2">
              <button
                onClick={() => void applyCountCorrection()}
                disabled={dispositionSaving}
                className="w-full rounded-lg bg-blue-600 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-40"
              >
                {dispositionSaving
                  ? "Saving…"
                  : "✓ Count correction (Enter)"}
              </button>
              {disposition.newQty < disposition.oldQty && (
                <button
                  onClick={goToRefillCapture}
                  disabled={dispositionSaving}
                  className="w-full rounded-lg border border-blue-300 py-2 text-sm font-semibold text-blue-700 hover:bg-blue-50 disabled:opacity-40 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950/30"
                >
                  → Refill to machine (
                  {disposition.oldQty - disposition.newQty} units)
                </button>
              )}
              {disposition.newQty < disposition.oldQty && (
                <button
                  onClick={() => void applyWriteOff()}
                  disabled={dispositionSaving}
                  className="w-full rounded-lg border border-red-300 py-2 text-sm font-semibold text-red-600 hover:bg-red-50 disabled:opacity-40 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/30"
                >
                  {disposition.newQty === 0
                    ? "🗑 Write off entire batch (expired/damaged)"
                    : "🗑 Write off (partial — logged as correction)"}
                </button>
              )}
              <button
                onClick={cancelDisposition}
                disabled={dispositionSaving}
                className="w-full rounded-lg bg-neutral-100 py-2 text-sm font-medium text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-700"
              >
                Cancel (Esc)
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Review toast */}
      {reviewToast && (
        <div className="fixed bottom-24 left-4 right-4 z-50 rounded-xl bg-green-100 px-4 py-3 text-center text-sm font-medium text-green-800 shadow-lg dark:bg-green-900 dark:text-green-200">
          {reviewToast}
        </div>
      )}

      {/* Floating "Complete control" button */}
      {controlMode && (
        <div className="fixed inset-x-0 bottom-20 z-30 px-4">
          <button
            onClick={completeControl}
            disabled={controlSaving}
            className="w-full rounded-xl bg-blue-600 py-3 text-sm font-semibold text-white shadow-lg hover:bg-blue-700 disabled:opacity-50"
          >
            {controlSaving ? "Saving..." : "Complete control"}
          </button>
        </div>
      )}
    </div>
  );
}
