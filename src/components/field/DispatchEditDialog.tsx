"use client";

import { useState, useTransition } from "react";
import {
  editDispatchQty,
  editDispatchShelf,
  editDispatchProduct,
  setDispatchSource,
  removeDispatchRow,
  searchBoonzProducts,
  listWarehouses,
  listActiveMachines,
  WH_CENTRAL_ID,
  type EditRole,
  type SourceKind,
} from "@/app/(field)/field/_actions/dispatch-edits";

type EditTab = "qty" | "shelf" | "product" | "source" | "remove";

interface Props {
  open: boolean;
  onClose: () => void;
  // Row context
  dispatchId: string;
  currentQty: number;
  currentShelfCode: string;
  currentBoonzName: string;
  currentSourceKind?: SourceKind;
  // Permissions
  editRole: EditRole;
  /** Which tabs to enable (depends on packed/picked_up/item_added state and editor role) */
  allowedTabs: EditTab[];
  /** Path to revalidate after a successful edit */
  revalidate?: string;
  /** Callback after successful edit so parent can refetch */
  onSuccess?: () => void;
}

export function DispatchEditDialog({
  open,
  onClose,
  dispatchId,
  currentQty,
  currentShelfCode,
  currentBoonzName,
  currentSourceKind = "wh",
  editRole,
  allowedTabs,
  revalidate,
  onSuccess,
}: Props) {
  const [tab, setTab] = useState<EditTab>(allowedTabs[0] ?? "qty");
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [reason, setReason] = useState("");

  // Per-tab inputs
  const [qty, setQty] = useState<number>(currentQty);
  const [shelfCode, setShelfCode] = useState<string>(currentShelfCode);
  const [productQuery, setProductQuery] = useState("");
  const [productResults, setProductResults] = useState<
    { product_id: string; boonz_product_name: string }[]
  >([]);
  const [selectedProductId, setSelectedProductId] = useState<string>("");
  const [sourceKind, setSourceKind] = useState<SourceKind>(currentSourceKind);
  const [warehouses, setWarehouses] = useState<
    { warehouse_id: string; name: string; display_name?: string | null }[]
  >([]);
  const [machines, setMachines] = useState<
    { machine_id: string; official_name: string }[]
  >([]);
  // Default warehouse selection to WH_CENTRAL so the picker isn't empty
  const [sourceWh, setSourceWh] = useState<string>(WH_CENTRAL_ID);
  const [sourceMachine, setSourceMachine] = useState<string>("");

  if (!open) return null;

  async function handleSearchProducts(q: string) {
    setProductQuery(q);
    if (q.length < 2) {
      setProductResults([]);
      return;
    }
    const r = await searchBoonzProducts(q);
    if (r.ok) setProductResults(r.data);
  }

  async function loadSourceOptions() {
    if (warehouses.length === 0) {
      const w = await listWarehouses();
      if (w.ok) setWarehouses(w.data);
    }
    if (machines.length === 0) {
      const m = await listActiveMachines();
      if (m.ok) setMachines(m.data);
    }
  }

  function handleSubmit() {
    setError(null);
    startTransition(async () => {
      let res;
      switch (tab) {
        case "qty":
          res = await editDispatchQty({
            dispatchId,
            newQty: qty,
            editRole,
            reason: reason || undefined,
            revalidate,
          });
          break;
        case "shelf":
          res = await editDispatchShelf({
            dispatchId,
            newShelfCode: shelfCode,
            editRole,
            reason: reason || undefined,
            revalidate,
          });
          break;
        case "product":
          if (!selectedProductId) {
            setError("Select a product first");
            return;
          }
          res = await editDispatchProduct({
            dispatchId,
            newBoonzProductId: selectedProductId,
            editRole,
            reason: reason || undefined,
            revalidate,
          });
          break;
        case "source":
          res = await setDispatchSource({
            dispatchId,
            sourceKind,
            sourceWarehouseId: sourceKind === "wh" ? sourceWh : undefined,
            sourceMachineId: sourceKind === "m2m" ? sourceMachine : undefined,
            editRole,
            reason: reason || undefined,
            revalidate,
          });
          break;
        case "remove":
          res = await removeDispatchRow({
            dispatchId,
            editRole,
            reason: reason || undefined,
            revalidate,
          });
          break;
      }
      if (res?.ok) {
        onSuccess?.();
        onClose();
      } else {
        setError(res?.error ?? "Edit failed");
      }
    });
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-4 shadow-lg dark:bg-slate-900">
        <div className="mb-3 flex items-start justify-between">
          <div>
            <h3 className="text-lg font-semibold">Edit dispatch row</h3>
            <p className="text-xs text-slate-500">
              {currentBoonzName} · shelf {currentShelfCode} · {currentQty} units
            </p>
          </div>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-600">
            ✕
          </button>
        </div>

        {/* Tabs */}
        <div className="mb-3 flex gap-1 border-b border-slate-200 dark:border-slate-700">
          {allowedTabs.map((t) => (
            <button
              key={t}
              onClick={() => {
                setTab(t);
                if (t === "source") void loadSourceOptions();
              }}
              className={`px-3 py-2 text-sm capitalize ${
                tab === t
                  ? "border-b-2 border-blue-500 font-medium text-blue-600"
                  : "text-slate-500"
              }`}
            >
              {t === "remove" ? "Remove row" : t}
            </button>
          ))}
        </div>

        {/* Body per tab */}
        {tab === "qty" && (
          <div className="space-y-3">
            <label className="block text-sm">
              New quantity
              <input
                type="number"
                value={qty}
                min={0}
                onChange={(e) => setQty(Number(e.target.value))}
                className="mt-1 w-full rounded border px-2 py-1"
              />
            </label>
          </div>
        )}

        {tab === "shelf" && (
          <div className="space-y-3">
            <label className="block text-sm">
              New shelf code
              <input
                type="text"
                value={shelfCode}
                onChange={(e) => setShelfCode(e.target.value)}
                placeholder="e.g. A05"
                className="mt-1 w-full rounded border px-2 py-1"
              />
            </label>
            <p className="text-xs text-amber-600">
              Driver only — must match an existing shelf on this machine.
            </p>
          </div>
        )}

        {tab === "product" && (
          <div className="space-y-3">
            <label className="block text-sm">
              Search products
              <input
                type="text"
                value={productQuery}
                onChange={(e) => handleSearchProducts(e.target.value)}
                placeholder="Type 2+ characters"
                className="mt-1 w-full rounded border px-2 py-1"
              />
            </label>
            {productResults.length > 0 && (
              <ul className="max-h-48 overflow-y-auto rounded border">
                {productResults.map((p) => (
                  <li
                    key={p.product_id}
                    onClick={() => setSelectedProductId(p.product_id)}
                    className={`cursor-pointer px-3 py-2 text-sm hover:bg-slate-100 ${
                      selectedProductId === p.product_id ? "bg-blue-50" : ""
                    }`}
                  >
                    {p.boonz_product_name}
                  </li>
                ))}
              </ul>
            )}
            <p className="text-xs text-amber-600">
              Substitutes the variant only — qty & shelf unchanged.
            </p>
          </div>
        )}

        {tab === "source" && (
          <div className="space-y-3">
            <label className="block text-sm">
              Source kind
              <select
                value={sourceKind}
                onChange={(e) => setSourceKind(e.target.value as SourceKind)}
                className="mt-1 w-full rounded border px-2 py-1"
              >
                <option value="wh">Warehouse</option>
                <option value="m2m">From another machine</option>
              </select>
            </label>
            {sourceKind === "wh" && (
              <label className="block text-sm">
                Warehouse
                <select
                  value={sourceWh}
                  onChange={(e) => setSourceWh(e.target.value)}
                  className="mt-1 w-full rounded border px-2 py-1"
                >
                  {warehouses.map((w) => (
                    <option key={w.warehouse_id} value={w.warehouse_id}>
                      {w.display_name ?? w.name}
                    </option>
                  ))}
                </select>
              </label>
            )}
            {sourceKind === "m2m" && (
              <label className="block text-sm">
                Source machine
                <select
                  value={sourceMachine}
                  onChange={(e) => setSourceMachine(e.target.value)}
                  className="mt-1 w-full rounded border px-2 py-1"
                >
                  <option value="">— pick —</option>
                  {machines.map((m) => (
                    <option key={m.machine_id} value={m.machine_id}>
                      {m.official_name}
                    </option>
                  ))}
                </select>
              </label>
            )}
          </div>
        )}

        {tab === "remove" && (
          <div className="space-y-3">
            <p className="text-sm text-red-600">
              This will mark the row as excluded from dispatch (soft-remove). The row
              persists for audit. WH manager only — must be before driver picks up.
            </p>
          </div>
        )}

        {/* Reason + actions */}
        <div className="mt-4 space-y-3">
          <label className="block text-sm">
            Reason (optional, recommended)
            <input
              type="text"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="e.g. WH short / wrong variant / drive substitution"
              className="mt-1 w-full rounded border px-2 py-1"
            />
          </label>
          {error && (
            <p className="rounded bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>
          )}
          <div className="flex justify-end gap-2">
            <button
              onClick={onClose}
              className="rounded border px-3 py-1 text-sm"
              disabled={isPending}
            >
              Cancel
            </button>
            <button
              onClick={handleSubmit}
              disabled={isPending}
              className="rounded bg-blue-600 px-3 py-1 text-sm font-medium text-white disabled:opacity-50"
            >
              {isPending ? "Saving..." : "Apply edit"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
