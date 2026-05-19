"use client";

import { useState, useTransition, useEffect } from "react";
import {
  addDispatchRow,
  searchBoonzProducts,
  listWarehouses,
  listActiveMachines,
  WH_CENTRAL_ID,
  type EditRole,
  type SourceKind,
} from "@/app/(field)/field/_actions/dispatch-edits";

interface Props {
  open: boolean;
  onClose: () => void;
  machineId: string;
  machineName: string;
  /** Pre-select a shelf if the dialog was opened from a specific shelf section */
  initialShelfCode?: string;
  /** ISO date string for the dispatch */
  dispatchDate: string;
  editRole: EditRole;
  revalidate?: string;
  onSuccess?: () => void;
}

export function AddDispatchRowDialog({
  open,
  onClose,
  machineId,
  machineName,
  initialShelfCode = "",
  dispatchDate,
  editRole,
  revalidate,
  onSuccess,
}: Props) {
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const [shelfCode, setShelfCode] = useState(initialShelfCode);
  const [action, setAction] = useState<"Refill" | "Add New" | "Remove">("Refill");
  const [productQuery, setProductQuery] = useState("");
  const [productResults, setProductResults] = useState<
    { product_id: string; boonz_product_name: string }[]
  >([]);
  const [selectedProduct, setSelectedProduct] = useState<{
    product_id: string;
    boonz_product_name: string;
  } | null>(null);
  const [quantity, setQuantity] = useState<number>(1);
  const [sourceKind, setSourceKind] = useState<SourceKind>("wh");
  const [warehouses, setWarehouses] = useState<
    { warehouse_id: string; name: string; display_name?: string | null }[]
  >([]);
  // Full active-machines list (incl. current). We filter at render time depending on action.
  const [allMachines, setAllMachines] = useState<
    { machine_id: string; official_name: string }[]
  >([]);
  // Default warehouse to WH_CENTRAL so the picker is never empty
  const [sourceWh, setSourceWh] = useState<string>(WH_CENTRAL_ID);
  const [sourceMachine, setSourceMachine] = useState<string>("");
  const [reason, setReason] = useState("");

  useEffect(() => {
    if (!open) return;
    (async () => {
      const w = await listWarehouses();
      if (w.ok) setWarehouses(w.data);
      const m = await listActiveMachines();
      if (m.ok) setAllMachines(m.data);
    })();
  }, [open, machineId]);

  // When action flips to/from "Remove", auto-default the source for machine-to-warehouse returns.
  // Remove = the current machine is the source (driver removing product from the machine).
  useEffect(() => {
    if (action === "Remove") {
      setSourceKind("m2m");
      setSourceMachine(machineId);
    } else if (sourceMachine === machineId) {
      // Reset stale Remove-mode selection if user switches back
      setSourceMachine("");
    }
  }, [action, machineId]);

  // Machine list visible in the picker:
  // - Remove action: include the CURRENT machine (so source can be the one we're removing from)
  // - Refill / Add New: exclude the current machine (M2M from another machine only)
  const machines =
    action === "Remove"
      ? allMachines
      : allMachines.filter((mm) => mm.machine_id !== machineId);

  if (!open) return null;

  async function handleSearchProducts(q: string) {
    setProductQuery(q);
    // If the user starts editing after a selection, clear the selection so they can re-pick
    if (selectedProduct && q !== selectedProduct.boonz_product_name) {
      setSelectedProduct(null);
    }
    if (q.length < 2) {
      setProductResults([]);
      return;
    }
    const r = await searchBoonzProducts(q);
    if (r.ok) setProductResults(r.data);
  }

  function handleSubmit() {
    setError(null);
    if (!selectedProduct) {
      setError("Select a product");
      return;
    }
    if (!shelfCode.trim()) {
      setError("Shelf code required");
      return;
    }
    if (quantity <= 0) {
      setError("Quantity must be > 0");
      return;
    }
    if (sourceKind === "wh" && !sourceWh) {
      setError("WH source: pick a warehouse");
      return;
    }
    if (sourceKind === "m2m" && !sourceMachine) {
      setError("M2M source: pick a source machine");
      return;
    }

    startTransition(async () => {
      const res = await addDispatchRow({
        machineId,
        shelfCode,
        boonzProductId: selectedProduct.product_id,
        quantity,
        action,
        dispatchDate,
        sourceKind,
        sourceWarehouseId: sourceKind === "wh" ? sourceWh : undefined,
        sourceMachineId: sourceKind === "m2m" ? sourceMachine : undefined,
        editRole,
        reason: reason || undefined,
        revalidate,
      });
      if (res.ok) {
        onSuccess?.();
        onClose();
      } else {
        setError(res.error ?? "Add failed");
      }
    });
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-4 shadow-lg dark:bg-slate-900">
        <div className="mb-3 flex items-start justify-between">
          <div>
            <h3 className="text-lg font-semibold">Add dispatch row</h3>
            <p className="text-xs text-slate-500">
              {machineName} · {dispatchDate}
            </p>
          </div>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-600">
            ✕
          </button>
        </div>

        <div className="space-y-3">
          <div className="flex gap-2">
            <label className="flex-1 text-sm">
              Shelf
              <input
                type="text"
                value={shelfCode}
                onChange={(e) => setShelfCode(e.target.value.toUpperCase())}
                placeholder="A05"
                className="mt-1 w-full rounded border px-2 py-1"
              />
            </label>
            <label className="flex-1 text-sm">
              Action
              <select
                value={action}
                onChange={(e) => setAction(e.target.value as typeof action)}
                className="mt-1 w-full rounded border px-2 py-1"
              >
                <option value="Refill">Refill</option>
                <option value="Add New">Add New</option>
                <option value="Remove">Remove</option>
              </select>
            </label>
          </div>

          <label className="block text-sm">
            Product
            <input
              type="text"
              value={productQuery}
              onChange={(e) => handleSearchProducts(e.target.value)}
              placeholder="Type 2+ characters to search"
              className={`mt-1 w-full rounded border px-2 py-1 ${
                selectedProduct ? "bg-blue-50" : ""
              }`}
            />
          </label>
          {productResults.length > 0 && !selectedProduct && (
            <ul className="max-h-40 overflow-y-auto rounded border">
              {productResults.map((p) => (
                <li
                  key={p.product_id}
                  onClick={() => {
                    setSelectedProduct(p);
                    setProductQuery(p.boonz_product_name);
                    setProductResults([]);
                  }}
                  className="cursor-pointer px-3 py-2 text-sm hover:bg-slate-100"
                >
                  {p.boonz_product_name}
                </li>
              ))}
            </ul>
          )}
          {selectedProduct && (
            <p className="text-xs text-blue-700">
              ✓ Selected: {selectedProduct.boonz_product_name} — start typing to change
            </p>
          )}

          <label className="block text-sm">
            Quantity
            <input
              type="number"
              min={1}
              value={quantity}
              onChange={(e) => setQuantity(Number(e.target.value))}
              className="mt-1 w-full rounded border px-2 py-1"
            />
          </label>

          <label className="block text-sm">
            Source
            <select
              value={sourceKind}
              onChange={(e) => setSourceKind(e.target.value as SourceKind)}
              className="mt-1 w-full rounded border px-2 py-1"
              disabled={action === "Remove"}
            >
              <option value="wh">Warehouse</option>
              <option value="m2m">From another machine</option>
            </select>
            {action === "Remove" && (
              <span className="text-xs text-slate-500">
                Returns are sourced from this machine — locked.
              </span>
            )}
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
                    {m.machine_id === machineId ? " (this machine)" : ""}
                  </option>
                ))}
              </select>
            </label>
          )}

          <label className="block text-sm">
            Reason (optional)
            <input
              type="text"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="e.g. driver pulled from truck inventory"
              className="mt-1 w-full rounded border px-2 py-1"
            />
          </label>
        </div>

        {error && (
          <p className="mt-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>
        )}

        <div className="mt-4 flex justify-end gap-2">
          <button
            onClick={onClose}
            disabled={isPending}
            className="rounded border px-3 py-1 text-sm"
          >
            Cancel
          </button>
          <button
            onClick={handleSubmit}
            disabled={isPending}
            className="rounded bg-blue-600 px-3 py-1 text-sm font-medium text-white disabled:opacity-50"
          >
            {isPending ? "Adding..." : "Add row"}
          </button>
        </div>
      </div>
    </div>
  );
}
