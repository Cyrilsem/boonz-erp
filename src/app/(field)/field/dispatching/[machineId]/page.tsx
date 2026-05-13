"use client";

import { useEffect, useState, useCallback, useMemo } from "react";
import { useParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../../components/field-header";
import { usePageTour } from "../../../components/onboarding/use-page-tour";
import Tour from "../../../components/onboarding/tour";
import { getExpiryStyle } from "@/app/(field)/utils/expiry";
import type { ExpiryWarning } from "@/lib/dispatch-types";

// ─── Types ────────────────────────────────────────────────────────────────────

interface MachineInfo {
  official_name: string;
  pod_location: string | null;
}

interface DispatchPhoto {
  path: string;
  url: string;
}

/** Driver outcome recorded for a dispatch line (UI-only, not stored as-is in DB) */
type LineAction = "added" | "returned" | null;

/** Planned action from refill_dispatching.action — drives label + RPC routing */
type DispatchAction = "Refill" | "Add New" | "Remove";

interface DispatchLine {
  dispatch_id: string;
  /** Planned action (Refill/Add New/Remove) — determines UI labels + which RPC to call */
  dispatch_action: DispatchAction;
  boonz_product_id: string | null;
  shelf_id: string | null;
  shelf_code: string | null;
  pod_product_name: string | null;
  boonz_product_name: string | null;
  quantity: number;
  filled_qty: number;
  dispatched: boolean;
  returned: boolean;
  return_reason: string;
  expiry_date: string | null;
  /** Expiry flag set by the refill engine at plan-write time */
  expiry_warning: ExpiryWarning | null;
  /** Source warehouse UUID */
  from_warehouse_id: string | null;
  /** Source warehouse display name (e.g. "WH_CENTRAL", "WH_MM") */
  from_warehouse_name: string | null;
  comment: string;
  action: LineAction;
  /** Driver-side confirmation flag for Remove (BUG-010) */
  driver_confirmed: boolean;
}

const RETURN_REASONS = [
  "Not added to machine",
  "Machine full",
  "Product damaged",
  "Wrong product",
  "Customer refused",
  "Machine offline",
  "Other",
] as const;

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatDMY(date: string | null): string {
  if (!date) return "—";
  return new Date(date + "T00:00:00").toLocaleDateString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "2-digit",
  });
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function DispatchingDetailPage() {
  const params = useParams<{ machineId: string }>();
  const machineId = params.machineId;
  const { showTour, tourSteps, completeTour } = usePageTour("dispatching");

  const [machine, setMachine] = useState<MachineInfo | null>(null);
  const [lines, setLines] = useState<DispatchLine[]>([]);
  const [invWarnings, setInvWarnings] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [editingAfterSave, setEditingAfterSave] = useState(false);
  const [returnNotice, setReturnNotice] = useState<string | null>(null);

  // BUG-010 #3: Driver can add extra Remove rows when planned line collapses
  // multi-variant returns (e.g. YoPro Vanilla 6u plan but actual is 2 Van + 2 Choco + 2 Straw).
  const [extraReturnOpen, setExtraReturnOpen] = useState(false);
  const [extraReturnShelf, setExtraReturnShelf] = useState<string | null>(null);
  const [extraReturnSearch, setExtraReturnSearch] = useState("");
  const [extraReturnQty, setExtraReturnQty] = useState(1);
  const [extraReturnAdding, setExtraReturnAdding] = useState(false);
  const [productOptions, setProductOptions] = useState<
    Array<{ product_id: string; boonz_product_name: string }>
  >([]);
  const [productSearchLoading, setProductSearchLoading] = useState(false);

  // Photos
  const [beforePhoto, setBeforePhoto] = useState<DispatchPhoto | null>(null);
  const [afterPhoto, setAfterPhoto] = useState<DispatchPhoto | null>(null);
  const [photoUploading, setPhotoUploading] = useState<
    "before" | "after" | null
  >(null);

  const fetchData = useCallback(async () => {
    const supabase = createClient();
    const today = getDubaiDate();

    const { data: machineData } = await supabase
      .from("machines")
      .select("official_name, pod_location")
      .eq("machine_id", machineId)
      .single();

    if (machineData) setMachine(machineData);

    // Build warehouse name map for badges
    const { data: warehouseRows } = await supabase
      .from("warehouses")
      .select("warehouse_id, name");
    const whNameMap = new Map<string, string>(
      (warehouseRows ?? []).map((w) => [
        w.warehouse_id as string,
        w.name as string,
      ]),
    );

    const { data: dispatchLines } = await supabase
      .from("refill_dispatching")
      .select(
        `
        dispatch_id,
        action,
        boonz_product_id,
        shelf_id,
        quantity,
        filled_quantity,
        dispatched,
        returned,
        return_reason,
        expiry_date,
        expiry_warning,
        from_warehouse_id,
        driver_confirmed_at,
        driver_confirmed_qty,
        comment,
        shelf_configurations(shelf_code),
        pod_products(pod_product_name)
      `,
      )
      .eq("dispatch_date", today)
      .eq("include", true)
      .eq("machine_id", machineId)
      .eq("picked_up", true);

    if (dispatchLines) {
      const mapped: DispatchLine[] = dispatchLines.map((line) => {
        const shelf = line.shelf_configurations as unknown as {
          shelf_code: string;
        } | null;
        const product = line.pod_products as unknown as {
          pod_product_name: string;
        } | null;
        const isDispatched = !!line.dispatched;
        const isReturned = !!(line.returned as boolean | null);
        const driverConfirmed = !!(line as Record<string, unknown>).driver_confirmed_at;
        let action: LineAction = null;
        if (isDispatched) action = "added";
        if (isReturned) action = "returned";
        if (driverConfirmed && !isReturned) action = "added"; // REMOVE: driver confirmed removal
        const whId =
          ((line as Record<string, unknown>).from_warehouse_id as
            | string
            | null) ?? null;
        // BUG-010 fix #2: auto-populate filled_qty with planned quantity on load
        // so driver only has to edit if reality differs.
        const planned = line.quantity ?? 0;
        const driverQty = ((line as Record<string, unknown>).driver_confirmed_qty as number | null) ?? null;
        const filledQtyDefault = driverQty ?? (line.filled_quantity != null && line.filled_quantity > 0 ? line.filled_quantity : planned);
        return {
          dispatch_id: line.dispatch_id,
          dispatch_action: ((line.action as string) ?? "Refill") as DispatchAction,
          boonz_product_id: (line.boonz_product_id as string | null) ?? null,
          shelf_id: (line.shelf_id as string | null) ?? null,
          shelf_code: shelf?.shelf_code ?? null,
          pod_product_name: product?.pod_product_name ?? null,
          boonz_product_name: null,
          quantity: planned,
          filled_qty: filledQtyDefault,
          dispatched: isDispatched,
          returned: isReturned,
          return_reason: (line.return_reason as string | null) ?? "",
          expiry_date: (line.expiry_date as string | null) ?? null,
          expiry_warning:
            ((line as Record<string, unknown>)
              .expiry_warning as ExpiryWarning | null) ?? null,
          from_warehouse_id: whId,
          from_warehouse_name: whId ? (whNameMap.get(whId) ?? null) : null,
          comment: (line.comment as string | null) ?? "",
          action,
          driver_confirmed: driverConfirmed,
        };
      });
      // Resolve boonz_product_name for each line so the driver sees the
      // brand-level name (e.g. "Evian - Regular") rather than the generic
      // pod name. Batch-fetch to avoid N+1 queries.
      const boonzIds = [
        ...new Set(
          mapped.map((l) => l.boonz_product_id).filter(Boolean) as string[],
        ),
      ];
      if (boonzIds.length > 0) {
        const { data: boonzNames } = await supabase
          .from("boonz_products")
          .select("product_id, boonz_product_name")
          .in("product_id", boonzIds)
          .limit(500);
        const boonzNameMap = new Map<string, string>(
          (boonzNames ?? []).map((b) => [
            b.product_id as string,
            b.boonz_product_name as string,
          ]),
        );
        for (const line of mapped) {
          if (line.boonz_product_id) {
            const resolved = boonzNameMap.get(line.boonz_product_id);
            if (resolved) line.boonz_product_name = resolved;
          }
        }
      }

      mapped.sort((a, b) =>
        (a.shelf_code ?? "").localeCompare(b.shelf_code ?? ""),
      );
      setLines(mapped);

      // If all lines already resolved on load, show read-only
      const allResolved =
        mapped.length > 0 && mapped.every((l) => l.action !== null);
      if (allResolved) setSaved(true);
    }

    // Photos for today
    const { data: photoData } = await supabase
      .from("dispatch_photos")
      .select("photo_type, storage_path")
      .eq("machine_id", machineId)
      .eq("dispatch_date", today);

    for (const p of photoData ?? []) {
      const {
        data: { publicUrl },
      } = supabase.storage.from("dispatch-photos").getPublicUrl(p.storage_path);
      if (p.photo_type === "before")
        setBeforePhoto({ path: p.storage_path, url: publicUrl });
      if (p.photo_type === "after")
        setAfterPhoto({ path: p.storage_path, url: publicUrl });
    }

    setLoading(false);
  }, [machineId]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Products with mixed expiry dates across their dispatch lines
  const mixedDateProducts = useMemo(() => {
    const byProduct = new Map<string, Set<string | null>>();
    for (const l of lines) {
      if (!l.boonz_product_id) continue;
      if (!byProduct.has(l.boonz_product_id))
        byProduct.set(l.boonz_product_id, new Set());
      byProduct.get(l.boonz_product_id)!.add(l.expiry_date);
    }
    const mixed = new Set<string>();
    for (const [pid, dates] of byProduct) {
      if (dates.size > 1) mixed.add(pid);
    }
    return mixed;
  }, [lines]);

  // ── Photo capture ──────────────────────────────────────────────────────────

  async function compressImage(file: File): Promise<Blob> {
    return new Promise((resolve) => {
      const img = new Image();
      const blobUrl = URL.createObjectURL(file);
      img.onload = () => {
        URL.revokeObjectURL(blobUrl);
        const maxW = 1200;
        let { width, height } = img;
        if (width > maxW) {
          height = Math.round((height * maxW) / width);
          width = maxW;
        }
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        const ctx = canvas.getContext("2d")!;
        ctx.drawImage(img, 0, 0, width, height);
        canvas.toBlob((blob) => resolve(blob!), "image/jpeg", 0.7);
      };
      img.src = blobUrl;
    });
  }

  async function handlePhotoCapture(type: "before" | "after", file: File) {
    setPhotoUploading(type);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    try {
      const compressed = await compressImage(file);
      const today = getDubaiDate();
      const timestamp = Date.now();
      const path = `${machineId}/${today}/${type}-${timestamp}.jpg`;

      const { error: uploadError } = await supabase.storage
        .from("dispatch-photos")
        .upload(path, compressed, { contentType: "image/jpeg" });
      if (uploadError) throw uploadError;

      const {
        data: { publicUrl },
      } = supabase.storage.from("dispatch-photos").getPublicUrl(path);

      await supabase.from("dispatch_photos").insert({
        machine_id: machineId,
        dispatch_date: today,
        photo_type: type,
        storage_path: path,
        taken_by: user?.id ?? null,
      });

      if (type === "before") setBeforePhoto({ path, url: publicUrl });
      else setAfterPhoto({ path, url: publicUrl });
    } catch {
      // Silent fail — photos are optional
    }

    setPhotoUploading(null);
  }

  // ── Line state helpers ─────────────────────────────────────────────────────

  function updateAction(dispatchId: string, action: LineAction) {
    setLines((prev) =>
      prev.map((l) => (l.dispatch_id === dispatchId ? { ...l, action } : l)),
    );
  }

  function updateReturnReason(dispatchId: string, reason: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, return_reason: reason } : l,
      ),
    );
  }

  function updateFilledQty(dispatchId: string, value: number) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, filled_qty: value } : l,
      ),
    );
  }

  function updateComment(dispatchId: string, value: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, comment: value } : l,
      ),
    );
  }

  // BUG-010 #3: search boonz_products for the Add Return Row modal
  const searchBoonzProducts = useCallback(async (q: string) => {
    if (q.length < 2) {
      setProductOptions([]);
      return;
    }
    setProductSearchLoading(true);
    const supabase = createClient();
    const { data } = await supabase
      .from("boonz_products")
      .select("product_id, boonz_product_name")
      .ilike("boonz_product_name", `%${q}%`)
      .limit(20);
    setProductOptions(
      (data ?? []) as Array<{ product_id: string; boonz_product_name: string }>,
    );
    setProductSearchLoading(false);
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => searchBoonzProducts(extraReturnSearch), 200);
    return () => clearTimeout(timer);
  }, [extraReturnSearch, searchBoonzProducts]);

  // Insert a sibling Remove row for the multi-variant split case
  async function handleAddExtraReturn(productId: string, productName: string) {
    if (!extraReturnShelf || extraReturnQty <= 0) return;
    setExtraReturnAdding(true);
    const supabase = createClient();
    const today = getDubaiDate();
    const shelfLine = lines.find((l) => l.shelf_code === extraReturnShelf);
    const { error } = await supabase.from("refill_dispatching").insert({
      machine_id: machineId,
      shelf_id: shelfLine?.shelf_id ?? null,
      pod_product_id: null,
      boonz_product_id: productId,
      dispatch_date: today,
      action: "Remove",
      quantity: extraReturnQty,
      filled_quantity: 0,
      include: true,
      packed: true,
      picked_up: true,
      dispatched: false,
      returned: false,
      item_added: false,
      comment: `[DRIVER ADDED] Multi-variant split — ${extraReturnQty}u ${productName}`,
    });
    if (error) {
      alert(`Could not add return row: ${error.message}`);
    } else {
      setExtraReturnOpen(false);
      setExtraReturnSearch("");
      setExtraReturnQty(1);
      setExtraReturnShelf(null);
      await fetchData();
    }
    setExtraReturnAdding(false);
  }

  function handleMarkAllAdded() {
    setLines((prev) =>
      prev.map((l) => ({
        ...l,
        action: "added" as LineAction,
        filled_qty: l.quantity,
      })),
    );
  }

  function handleMarkAllReturned() {
    setLines((prev) =>
      prev.map((l) => ({
        ...l,
        action: "returned" as LineAction,
        filled_qty: 0,
        return_reason: l.return_reason || "Not added to machine",
      })),
    );
  }

  // ── Save dispatch ──────────────────────────────────────────────────────────

  async function handleSave() {
    setSaving(true);
    setReturnNotice(null);
    const supabase = createClient();
    let totalReturnDelta = 0;

    for (const line of lines) {
      if (line.action === "added") {
        // BUG-010 routing: For REMOVE actions, "added" semantically means
        // "driver successfully removed from machine". Route to driver_confirm_remove
        // which stamps driver_confirmed_qty WITHOUT yet crediting warehouse_stock
        // or archiving pod_inventory. WH manager approves later in Inventory tab.
        const isRemove = line.dispatch_action === "Remove";
        const rpcName = isRemove ? "driver_confirm_remove" : "receive_dispatch_line";
        const rpcArgs = isRemove
          ? {
              p_dispatch_id: line.dispatch_id,
              p_qty_removed: line.filled_qty,
              p_batch_breakdown: null,
              p_driver_id: null,
              p_notes: line.comment.trim() || null,
            }
          : {
              p_dispatch_id: line.dispatch_id,
              p_filled_quantity: line.filled_qty,
            };

        const { data: rpcData, error: rpcErr } = await supabase.rpc(
          rpcName,
          rpcArgs,
        );

        if (rpcErr) {
          const msg = rpcErr.message ?? "";
          if (msg.includes("already received")) {
            // Idempotent — line was already received in a prior submit
            console.info("[Dispatch] line already received:", line.dispatch_id);
          } else {
            console.error("[Dispatch] receive_dispatch_line error:", rpcErr);
            setInvWarnings((prev) => ({
              ...prev,
              [line.dispatch_id]: "⚠ Receive failed: " + msg,
            }));
            continue;
          }
        } else if (rpcData) {
          const result = rpcData as { return_delta?: number | string };
          const delta = Number(result.return_delta ?? 0);
          if (delta > 0) totalReturnDelta += delta;
        }

        // Comment isn't touched by the RPC; persist it separately if set.
        if (line.comment.trim()) {
          await supabase
            .from("refill_dispatching")
            .update({ comment: line.comment.trim() })
            .eq("dispatch_id", line.dispatch_id);
        }
      } else if (line.action === "returned") {
        // B3.2: return_dispatch_line RPC replaces the legacy inline flow.
        // The RPC atomically drains consumer_stock on the packed batch,
        // restores warehouse_stock on the SAME row (no RETURN-DISPATCH
        // duplicate), flips returned=true, and is idempotent.
        const { data: rpcData, error: rpcErr } = await supabase.rpc(
          "return_dispatch_line",
          {
            p_dispatch_id: line.dispatch_id,
            p_return_reason: line.return_reason || null,
          },
        );

        if (rpcErr) {
          console.error("[B3.2] return_dispatch_line failed:", rpcErr);
          setInvWarnings((prev) => ({
            ...prev,
            [line.dispatch_id]:
              "⚠ Return failed: " + (rpcErr.message ?? "unknown error"),
          }));
          continue;
        }

        const status = (rpcData as { status?: string } | null)?.status;
        if (status === "already_returned") {
          console.info("[B3.2] already returned — no-op:", line.dispatch_id);
          setInvWarnings((prev) => ({
            ...prev,
            [line.dispatch_id]: "ℹ Already returned earlier — no change",
          }));
        } else {
          const returnQty = Number(
            (rpcData as { return_qty?: number | string } | null)?.return_qty ??
              0,
          );
          if (returnQty > 0) totalReturnDelta += returnQty;
        }

        // Persist driver comment separately — the RPC doesn't touch comment.
        if (line.comment.trim()) {
          await supabase
            .from("refill_dispatching")
            .update({ comment: line.comment.trim() })
            .eq("dispatch_id", line.dispatch_id);
        }

        // Mark local state so a second click immediately no-ops even if
        // the user doesn't re-submit to pick up the DB write.
        setLines((prev) =>
          prev.map((l) =>
            l.dispatch_id === line.dispatch_id
              ? { ...l, returned: true, dispatched: true, filled_qty: 0 }
              : l,
          ),
        );
      }
    }

    if (totalReturnDelta > 0) {
      setReturnNotice(
        `Returned ${totalReturnDelta} unit${totalReturnDelta === 1 ? "" : "s"} to warehouse.`,
      );
    }

    // B3.2: re-fetch authoritative state after the save loop so the UI
    // reflects RPC-driven changes (returned/dispatched/filled_quantity,
    // consumer_stock drains, any RETURN fallback rows) — no optimistic
    // caching beyond the per-line local state above.
    await fetchData();

    setSaving(false);
    setSaved(true);
    setEditingAfterSave(false);
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Dispatch Detail" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading dispatch details…</p>
        </div>
      </>
    );
  }

  // Detect if all lines were already dispatched in DB (completed machine)
  const allDispatchedFromDB =
    lines.length > 0 && lines.every((l) => l.dispatched || l.returned);

  if (allDispatchedFromDB && !editingAfterSave) {
    const today = getDubaiDate();
    return (
      <div className="px-4 py-4">
        <FieldHeader title="Dispatch Detail" />
        <div className="mx-auto max-w-md">
          {returnNotice && (
            <div className="mb-3 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-xs font-medium text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
              ↩ {returnNotice}
            </div>
          )}
          <div className="rounded-xl border border-green-200 bg-green-50 dark:border-green-900 dark:bg-green-950/30">
            <div className="border-b border-green-200 px-4 py-3 dark:border-green-900">
              <p className="text-lg font-bold text-green-700 dark:text-green-400">
                ✓ Dispatch Complete
              </p>
              <p className="text-xs text-green-600 dark:text-green-500">
                {machine?.official_name ?? ""} · {formatDMY(today)}
              </p>
            </div>
            <ul className="divide-y divide-green-100 dark:divide-green-900/50">
              {lines.map((line) => (
                <li
                  key={line.dispatch_id}
                  className="flex items-center justify-between px-4 py-2.5"
                >
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="shrink-0 rounded bg-green-100 px-1.5 py-0.5 text-xs font-mono text-green-600 dark:bg-green-900/40 dark:text-green-400">
                      {line.shelf_code ?? "—"}
                    </span>
                    <span className="text-sm truncate">
                      {line.boonz_product_name ?? line.pod_product_name ?? "—"}
                    </span>
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    {/* BUG-010 #5: show -N for Remove rows (retraction), ×N otherwise */}
                    {line.dispatch_action === "Remove" ? (
                      <span className="text-sm font-medium text-rose-700 dark:text-rose-400">
                        −{line.filled_qty || line.quantity}
                      </span>
                    ) : (
                      <span className="text-sm font-medium">
                        ×{line.filled_qty || line.quantity}
                      </span>
                    )}
                    {line.expiry_date && (
                      <span className="text-xs text-neutral-400">
                        {formatDMY(line.expiry_date)}
                      </span>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          </div>
          <button
            onClick={() => window.history.back()}
            className="mt-4 w-full rounded-lg border border-neutral-300 py-3 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-800"
          >
            ← Back
          </button>
        </div>
      </div>
    );
  }

  const allActioned = lines.length > 0 && lines.every((l) => l.action !== null);
  const addedCount = lines.filter((l) => l.action === "added").length;
  const returnedCount = lines.filter((l) => l.action === "returned").length;

  const isReadOnly = saved && !editingAfterSave;

  const grouped = new Map<string, DispatchLine[]>();
  for (const line of lines) {
    const key = line.shelf_code ?? "—";
    const existing = grouped.get(key) ?? [];
    existing.push(line);
    grouped.set(key, existing);
  }
  const shelves = Array.from(grouped.entries()).sort((a, b) =>
    a[0].localeCompare(b[0]),
  );

  return (
    <div className="px-4 py-4 pb-40">
      <div className="flex items-start justify-between">
        <FieldHeader title="Dispatch Detail" />
        <button
          onClick={fetchData}
          className="mt-1 shrink-0 rounded border border-neutral-300 px-2 py-1.5 text-xs text-neutral-500 transition-colors hover:bg-neutral-100 dark:border-neutral-600 dark:text-neutral-400 dark:hover:bg-neutral-800"
        >
          ↺ Refresh
        </button>
      </div>
      {showTour && tourSteps.length > 0 && (
        <Tour
          steps={tourSteps}
          onComplete={completeTour}
          onSkip={completeTour}
        />
      )}

      {/* ── Machine photos ── */}
      <div data-tour="dispatch-photos" className="mb-5">
        <p className="text-sm font-bold uppercase tracking-wide text-neutral-500">
          Machine photos
        </p>
        <p className="mb-3 text-xs text-neutral-400">
          Take a photo before and after refilling
        </p>
        <div className="grid grid-cols-2 gap-3">
          {(["before", "after"] as const).map((type) => {
            const photo = type === "before" ? beforePhoto : afterPhoto;
            const uploading = photoUploading === type;
            return (
              <div key={type} className="relative">
                {photo ? (
                  <div className="relative overflow-hidden rounded-xl">
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img
                      src={photo.url}
                      alt={`${type} photo`}
                      className="h-32 w-full object-cover"
                    />
                    <label className="absolute bottom-1 right-1 cursor-pointer rounded-lg bg-black/60 px-2 py-0.5 text-xs text-white">
                      Retake
                      <input
                        type="file"
                        accept="image/*"
                        capture="environment"
                        className="sr-only"
                        onChange={(e) => {
                          const file = e.target.files?.[0];
                          if (file) handlePhotoCapture(type, file);
                        }}
                      />
                    </label>
                  </div>
                ) : (
                  <label className="flex h-32 cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-neutral-300 bg-neutral-50 text-neutral-400 transition-colors hover:bg-neutral-100 dark:border-neutral-600 dark:bg-neutral-900 dark:hover:bg-neutral-800">
                    {uploading ? (
                      <span className="text-xs">Uploading…</span>
                    ) : (
                      <>
                        <span className="text-2xl">📷</span>
                        <span className="text-xs font-medium capitalize">
                          {type}
                        </span>
                        <span className="text-xs">Tap to capture</span>
                      </>
                    )}
                    <input
                      type="file"
                      accept="image/*"
                      capture="environment"
                      className="sr-only"
                      disabled={uploading}
                      onChange={(e) => {
                        const file = e.target.files?.[0];
                        if (file) handlePhotoCapture(type, file);
                      }}
                    />
                  </label>
                )}
              </div>
            );
          })}
        </div>
      </div>

      {machine && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{machine.official_name}</h1>
          <div className="flex items-center gap-2">
            {machine.pod_location && (
              <p className="text-sm text-neutral-500">{machine.pod_location}</p>
            )}
          </div>
        </div>
      )}

      {/* ── Save summary (after save) ── */}
      {saved && (
        <div className="mb-4 rounded-xl bg-green-50 px-4 py-3 text-sm dark:bg-green-950/30">
          <span className="font-medium text-green-700 dark:text-green-400">
            ✓ {addedCount} added to machine
          </span>
          {returnedCount > 0 && (
            <span className="ml-3 font-medium text-amber-700 dark:text-amber-400">
              ↩ {returnedCount} returned to warehouse
            </span>
          )}
        </div>
      )}

      {/* ── Dispatch lines ── */}
      {shelves.map(([shelfCode, shelfLines], idx) => (
        <div
          key={shelfCode}
          {...(idx === 0 ? { "data-tour": "dispatch-lines" } : {})}
          className="mb-4"
        >
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
            Shelf {shelfCode}
          </h2>
          <ul className="space-y-2">
            {shelfLines.map((line) => {
              const expiryStyle = getExpiryStyle(line.expiry_date);
              const isMixed = line.boonz_product_id
                ? mixedDateProducts.has(line.boonz_product_id)
                : false;
              const invWarning = invWarnings[line.dispatch_id];

              const borderClass =
                line.action === "added"
                  ? "border-l-4 border-l-green-400"
                  : line.action === "returned"
                    ? "border-l-4 border-l-amber-400"
                    : "";

              return (
                <li
                  key={line.dispatch_id}
                  className={`rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950 ${borderClass}`}
                >
                  {/* Product name + expiry */}
                  <div className="mb-2 flex items-start justify-between gap-2">
                    <p className="text-sm font-medium">
                      {line.boonz_product_name ??
                        line.pod_product_name ??
                        "Unknown product"}
                    </p>
                    <div className="flex shrink-0 flex-col items-end gap-1">
                      {/* Expiry: engine flag takes precedence over date-based style */}
                      {line.expiry_warning === "expired" ? (
                        <span className="rounded px-1 py-0.5 text-xs font-semibold bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-400">
                          ⚠ EXPIRED
                        </span>
                      ) : line.expiry_warning === "expiring_soon" ? (
                        <span className="rounded px-1 py-0.5 text-xs font-semibold bg-amber-100 text-amber-700 dark:bg-amber-950/40 dark:text-amber-400">
                          ⚠ Expires soon
                        </span>
                      ) : line.expiry_date ? (
                        <span className={`text-xs ${expiryStyle.qtyColor}`}>
                          {formatDMY(line.expiry_date)}
                        </span>
                      ) : null}
                      {/* Warehouse source badge */}
                      {line.from_warehouse_name && (
                        <span className="rounded bg-blue-50 px-1.5 py-0.5 text-xs font-medium text-blue-600 dark:bg-blue-950/40 dark:text-blue-400">
                          📦 {line.from_warehouse_name}
                        </span>
                      )}
                    </div>
                  </div>

                  {isMixed && (
                    <p className="mb-2 inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                      ⚠ Mixed dates — load oldest first
                    </p>
                  )}

                  {invWarning && (
                    <p className="mb-2 text-xs text-amber-600 dark:text-amber-400">
                      {invWarning}
                    </p>
                  )}

                  {/* Qty */}
                  <div className="mb-2 flex items-center gap-2">
                    <span className="text-xs text-neutral-500">
                      Planned: {line.quantity}
                    </span>
                    <span className="text-xs text-neutral-400">·</span>
                    <label className="text-xs text-neutral-500">Filled:</label>
                    <input
                      type="number"
                      min={0}
                      value={line.filled_qty}
                      onChange={(e) =>
                        updateFilledQty(
                          line.dispatch_id,
                          parseFloat(e.target.value) || 0,
                        )
                      }
                      disabled={isReadOnly}
                      className="w-16 rounded border border-neutral-300 px-2 py-1 text-center text-sm disabled:opacity-50 dark:border-neutral-600 dark:bg-neutral-900"
                    />
                  </div>

                  {/* Action badge — show planned action type so driver knows what's expected */}
                  <div className="mb-2 flex items-center gap-2 text-xs">
                    {line.dispatch_action === "Remove" ? (
                      <span className="rounded bg-rose-50 px-1.5 py-0.5 font-semibold uppercase tracking-wide text-rose-700 dark:bg-rose-950/40 dark:text-rose-400">
                        REMOVE
                      </span>
                    ) : line.dispatch_action === "Add New" ? (
                      <span className="rounded bg-purple-50 px-1.5 py-0.5 font-semibold uppercase tracking-wide text-purple-700 dark:bg-purple-950/40 dark:text-purple-400">
                        ADD NEW
                      </span>
                    ) : (
                      <span className="rounded bg-sky-50 px-1.5 py-0.5 font-semibold uppercase tracking-wide text-sky-700 dark:bg-sky-950/40 dark:text-sky-400">
                        REFILL
                      </span>
                    )}
                  </div>

                  {/* Action toggle — labels depend on the planned action */}
                  {!isReadOnly && (
                    <div className="mb-2 flex gap-2">
                      <button
                        onClick={() => updateAction(line.dispatch_id, "added")}
                        className={`flex-1 rounded-lg border py-1.5 text-xs font-semibold transition-colors ${
                          line.action === "added"
                            ? "border-green-400 bg-green-50 text-green-700 dark:bg-green-950/40 dark:text-green-400"
                            : "border-neutral-200 text-neutral-500 hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-800"
                        }`}
                      >
                        {line.dispatch_action === "Remove"
                          ? "✓ Removed from machine"
                          : "✓ Added to machine"}
                      </button>
                      <button
                        onClick={() =>
                          updateAction(line.dispatch_id, "returned")
                        }
                        className={`flex-1 rounded-lg border py-1.5 text-xs font-semibold transition-colors ${
                          line.action === "returned"
                            ? "border-amber-400 bg-amber-50 text-amber-700 dark:bg-amber-950/40 dark:text-amber-400"
                            : "border-neutral-200 text-neutral-500 hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-800"
                        }`}
                      >
                        {line.dispatch_action === "Remove"
                          ? "↩ Could not remove"
                          : "↩ Returned"}
                      </button>
                    </div>
                  )}

                  {/* Return reason (if returned) */}
                  {line.action === "returned" && !isReadOnly && (
                    <div className="mb-2">
                      <label className="mb-0.5 block text-xs text-neutral-500">
                        Return reason
                      </label>
                      <select
                        value={line.return_reason}
                        onChange={(e) =>
                          updateReturnReason(line.dispatch_id, e.target.value)
                        }
                        className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                      >
                        <option value="">Select reason…</option>
                        {RETURN_REASONS.map((r) => (
                          <option key={r} value={r}>
                            {r}
                          </option>
                        ))}
                      </select>
                    </div>
                  )}

                  {/* Read-only return reason */}
                  {line.action === "returned" &&
                    isReadOnly &&
                    line.return_reason && (
                      <p className="mb-2 text-xs text-amber-600 dark:text-amber-400">
                        Reason: {line.return_reason}
                      </p>
                    )}

                  {/* Comment */}
                  <input
                    type="text"
                    value={line.comment}
                    onChange={(e) =>
                      updateComment(line.dispatch_id, e.target.value)
                    }
                    disabled={isReadOnly}
                    placeholder="Add a note…"
                    className="w-full rounded border border-neutral-200 px-2 py-1 text-xs text-neutral-600 placeholder:text-neutral-400 disabled:opacity-50 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-400"
                  />
                </li>
              );
            })}
          </ul>
          {/* BUG-010 #3: split a planned return into multiple sibling variants */}
          {!isReadOnly && (
            <button
              onClick={() => {
                setExtraReturnShelf(shelfCode);
                setExtraReturnOpen(true);
                setExtraReturnSearch("");
                setExtraReturnQty(1);
              }}
              className="mt-2 w-full rounded-lg border border-dashed border-rose-300 py-2 text-xs font-medium text-rose-700 transition-colors hover:bg-rose-50 dark:border-rose-800 dark:text-rose-400 dark:hover:bg-rose-950/30"
            >
              + Add another return on shelf {shelfCode} (different variant)
            </button>
          )}
        </div>
      ))}

      {/* BUG-010 #3: Add-extra-return modal */}
      {extraReturnOpen && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 sm:items-center">
          <div className="w-full max-w-md rounded-t-2xl bg-white p-4 dark:bg-neutral-900 sm:rounded-2xl">
            <div className="mb-3 flex items-center justify-between">
              <h2 className="text-base font-bold">
                Add return — shelf {extraReturnShelf}
              </h2>
              <button
                onClick={() => setExtraReturnOpen(false)}
                className="rounded p-1 text-neutral-500 hover:bg-neutral-100 dark:hover:bg-neutral-800"
                aria-label="Close"
              >
                ✕
              </button>
            </div>
            <p className="mb-3 text-xs text-neutral-500">
              Use this when the planned return collapses multiple variants
              (e.g. plan said 6 YoPro Vanilla but you have 2 Van + 2 Choco + 2 Straw).
            </p>
            <input
              type="text"
              value={extraReturnSearch}
              onChange={(e) => setExtraReturnSearch(e.target.value)}
              placeholder="Search product name…"
              autoFocus
              className="mb-2 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-950"
            />
            {productSearchLoading && (
              <p className="mb-2 text-xs text-neutral-400">Searching…</p>
            )}
            {productOptions.length > 0 && (
              <ul className="mb-3 max-h-56 overflow-y-auto rounded-lg border border-neutral-200 bg-white dark:border-neutral-700 dark:bg-neutral-950">
                {productOptions.map((opt) => (
                  <li key={opt.product_id}>
                    <button
                      onClick={() =>
                        handleAddExtraReturn(opt.product_id, opt.boonz_product_name)
                      }
                      disabled={extraReturnAdding || extraReturnQty <= 0}
                      className="block w-full px-3 py-2 text-left text-sm hover:bg-rose-50 disabled:opacity-50 dark:hover:bg-rose-950/30"
                    >
                      {opt.boonz_product_name}
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <label className="mb-3 block text-xs text-neutral-500">
              Qty to return
              <input
                type="number"
                min={1}
                value={extraReturnQty}
                onChange={(e) =>
                  setExtraReturnQty(parseFloat(e.target.value) || 0)
                }
                className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-950"
              />
            </label>
            <p className="text-xs text-neutral-400">
              Tap a product above to add it as an extra REMOVE row on this shelf.
            </p>
          </div>
        </div>
      )}

      {/* ── Bottom bar ── */}
      <div className="fixed bottom-14 left-0 right-0 border-t border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        {isReadOnly ? (
          <button
            onClick={() => {
              setSaved(false);
              setEditingAfterSave(true);
            }}
            className="w-full rounded-lg border border-neutral-300 py-3 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-800"
          >
            Edit
          </button>
        ) : (
          <div className="space-y-2">
            <div className="grid grid-cols-2 gap-2">
              <button
                onClick={handleMarkAllAdded}
                className="rounded-lg border border-neutral-300 py-2.5 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-800"
              >
                ✓ All added
              </button>
              <button
                onClick={handleMarkAllReturned}
                className="rounded-lg border border-amber-300 py-2.5 text-sm font-medium text-amber-700 transition-colors hover:bg-amber-50 dark:border-amber-700 dark:text-amber-400 dark:hover:bg-amber-950/30"
              >
                ↩ All returned
              </button>
            </div>
            <button
              onClick={handleSave}
              disabled={!allActioned || saving}
              className="w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              {saving
                ? "Saving…"
                : allActioned
                  ? `Save dispatch (${addedCount} added, ${returnedCount} returned)`
                  : `Save dispatch — ${lines.filter((l) => l.action === null).length} pending`}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
