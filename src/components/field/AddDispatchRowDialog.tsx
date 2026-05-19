"use client";

import { useState, useTransition, useEffect } from "react";
import {
  addDispatchRow,
  searchBoonzProducts,
  listWarehouses,
  listActiveMachines,
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
    { warehouse_id: string; name: string; code: string }[]
  >([]);
  const [machines, setMachines] = useState<
    { machine_id: string; official_name: string }[]
  >([]);
  const [sourceWh, setSourceWh] = useState<string>("");
  const [sourceMachine, setSourceMachine] = useState<string>("");
  const [reason, setReason] = useState("");

  useEffect(() => {
    if (!open) return;
    (async () => {
      const w = await listWarehouses();
      if (w.ok) setWarehouses(w.data);
      const m = await listActiveMachines();
      if (m.ok) setMachines(m.data.filter((mm) => mm.machine_id !== machineId));
    })();
  }, [open, machineId]);

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
    if ((sourceKind === "m2m" || sourceKind === "truck_transfer") && !sourceMachine) {
      setError(`${sourceKind} source: pick a source machine`);
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
        sourceMachineId:
          sourceKind === "m2m" || sourceKind === "truck_transfer" ? sourceMachine : undefined,
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
              className="mt-1 w-full rounded border px-2 py-1"
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
            <div className="rounded bg-blue-50 px-3 py-2 text-sm">
              ✓ {selectedProduct.boonz_product_name}{" "}
              <button
                onClick={() => {
                  setSelectedProduct(null);
                  setProductQuery("");
                }}
                className="ml-2 text-xs text-blue-700 underline"
              >
                change
              </button>
            </div>
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
            >
              <option value="wh">Warehouse</option>
              <option value="m2m">From another machine (M2M)</option>
              <option value="truck_transfer">Truck transfer</option>
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
                <option value="">— pick —</option>
                {warehouses.map((w) => (
                  <option key={w.warehouse_id} value={w.warehouse_id}>
                    {w.name} ({w.code})
                  </option>
                ))}
              </select>
            </label>
          )}

          {(sourceKind === "m2m" || sourceKind === "truck_transfer") && (
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
