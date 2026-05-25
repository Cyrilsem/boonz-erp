"use client";

// PRD-012 B.2: Add Product dialog (driver-side).
// Calls propose_pod_inventory_add with a client-generated correlation_id.
// Shelves with an Active pod_inventory row are shown but disabled (D2).

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface Shelf {
  shelf_id: string;
  shelf_code: string;
  max_capacity: number | null;
  occupied_by_product: string | null;
}

interface Product {
  product_id: string;
  boonz_product_name: string;
  product_category: string | null;
}

interface AddProductDialogProps {
  machineId: string;
  machineName: string;
  onClose: () => void;
  onSubmitted: () => void;
}

function todayPlus(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

export default function AddProductDialog(props: AddProductDialogProps) {
  const { machineId, machineName, onClose, onSubmitted } = props;
  const supabase = useMemo(() => createClient(), []);

  const [shelves, setShelves] = useState<Shelf[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [loading, setLoading] = useState(true);

  const [selectedShelfId, setSelectedShelfId] = useState<string>("");
  const [productSearch, setProductSearch] = useState("");
  const [selectedProductId, setSelectedProductId] = useState<string>("");
  const [quantity, setQuantity] = useState<number>(1);
  const [expiry, setExpiry] = useState<string>(todayPlus(180));
  const [notes, setNotes] = useState<string>("");

  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [shelfRes, podRes, productRes] = await Promise.all([
        supabase
          .from("shelf_configurations")
          .select("shelf_id, shelf_code, max_capacity")
          .eq("machine_id", machineId)
          .order("shelf_code", { ascending: true })
          .limit(10000),
        supabase
          .from("pod_inventory")
          .select(
            "shelf_id, boonz_product_id, boonz_products(boonz_product_name)",
          )
          .eq("machine_id", machineId)
          .eq("status", "Active")
          .limit(10000),
        supabase
          .from("boonz_products")
          .select("product_id, boonz_product_name, product_category")
          .order("boonz_product_name", { ascending: true })
          .limit(10000),
      ]);
      if (cancelled) return;

      const occMap = new Map<string, string>();
      for (const row of podRes.data ?? []) {
        const bp = row.boonz_products as unknown as {
          boonz_product_name: string;
        } | null;
        if (row.shelf_id) {
          occMap.set(
            row.shelf_id,
            bp?.boonz_product_name ?? "(unknown product)",
          );
        }
      }

      const shelfList: Shelf[] = (shelfRes.data ?? []).map((s) => ({
        shelf_id: s.shelf_id,
        shelf_code: s.shelf_code,
        max_capacity: s.max_capacity ?? null,
        occupied_by_product: occMap.get(s.shelf_id) ?? null,
      }));
      setShelves(shelfList);

      const productList: Product[] = (productRes.data ?? []) as Product[];
      setProducts(productList);
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [supabase, machineId]);

  const selectedShelf = shelves.find((s) => s.shelf_id === selectedShelfId);
  const selectedProduct = products.find(
    (p) => p.product_id === selectedProductId,
  );

  const filteredProducts = useMemo(() => {
    const q = productSearch.trim().toLowerCase();
    if (!q) return products.slice(0, 25);
    return products
      .filter(
        (p) =>
          p.boonz_product_name.toLowerCase().includes(q) ||
          (p.product_category ?? "").toLowerCase().includes(q),
      )
      .slice(0, 25);
  }, [products, productSearch]);

  const maxExpiry = todayPlus(36 * 30); // approximate; backend enforces strict 36mo bound
  const minExpiry = todayPlus(1);

  const formValid =
    !!selectedShelfId &&
    !!selectedProductId &&
    quantity > 0 &&
    (selectedShelf?.max_capacity == null ||
      quantity <= selectedShelf.max_capacity) &&
    !!expiry &&
    expiry > new Date().toISOString().slice(0, 10);

  async function handleSubmit() {
    if (!formValid || submitting) return;
    setSubmitError(null);
    setSubmitting(true);
    const correlation =
      typeof crypto !== "undefined" && "randomUUID" in crypto
        ? crypto.randomUUID()
        : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const { data, error } = await supabase.rpc("propose_pod_inventory_add", {
      p_machine_id: machineId,
      p_shelf_id: selectedShelfId,
      p_boonz_product_id: selectedProductId,
      p_quantity: quantity,
      p_expiration_date: expiry,
      p_notes: notes.trim() || null,
      p_photo_path: null,
      p_correlation_id: correlation,
    });
    setSubmitting(false);
    if (error) {
      setSubmitError(error.message ?? String(error));
      return;
    }
    const result = (data as { result?: string } | null)?.result;
    if (result === "success") {
      alert(
        `Submitted for review: ${selectedProduct?.boonz_product_name ?? "product"} (qty ${quantity}) on shelf ${selectedShelf?.shelf_code ?? "?"}.`,
      );
      onSubmitted();
      onClose();
    } else if (result === "idempotent_replay") {
      alert("Already submitted (idempotent retry).");
      onSubmitted();
      onClose();
    } else {
      setSubmitError(`Unexpected RPC response: ${JSON.stringify(data)}`);
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center"
      onClick={onClose}
    >
      <div
        className="w-full max-w-md rounded-t-2xl bg-white p-4 shadow-xl sm:rounded-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-base font-semibold">
            Add Product to {machineName}
          </h3>
          <button
            type="button"
            onClick={onClose}
            className="text-neutral-500 hover:text-neutral-700"
            aria-label="Close"
          >
            ✕
          </button>
        </div>

        {loading ? (
          <p className="py-8 text-center text-sm text-neutral-500">Loading…</p>
        ) : (
          <div className="space-y-3">
            {/* Shelf picker */}
            <label className="block text-xs font-medium text-neutral-700">
              Shelf
              <select
                value={selectedShelfId}
                onChange={(e) => setSelectedShelfId(e.target.value)}
                className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm"
              >
                <option value="">Pick a shelf...</option>
                {shelves.map((s) => (
                  <option
                    key={s.shelf_id}
                    value={s.shelf_id}
                    disabled={!!s.occupied_by_product}
                  >
                    {s.shelf_code}
                    {s.max_capacity != null ? ` (cap ${s.max_capacity})` : ""}
                    {s.occupied_by_product
                      ? ` — in use by ${s.occupied_by_product}`
                      : ""}
                  </option>
                ))}
              </select>
            </label>

            {/* Product search + select */}
            <label className="block text-xs font-medium text-neutral-700">
              Product
              <input
                type="text"
                value={productSearch}
                onChange={(e) => setProductSearch(e.target.value)}
                placeholder="Search product name or category"
                className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm"
              />
              <select
                value={selectedProductId}
                onChange={(e) => setSelectedProductId(e.target.value)}
                className="mt-2 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm"
                size={Math.min(6, Math.max(2, filteredProducts.length))}
              >
                {filteredProducts.length === 0 ? (
                  <option value="" disabled>
                    No products match
                  </option>
                ) : (
                  filteredProducts.map((p) => (
                    <option key={p.product_id} value={p.product_id}>
                      {p.boonz_product_name}
                      {p.product_category ? ` (${p.product_category})` : ""}
                    </option>
                  ))
                )}
              </select>
            </label>

            {/* Quantity */}
            <label className="block text-xs font-medium text-neutral-700">
              Quantity
              <input
                type="number"
                min={1}
                max={selectedShelf?.max_capacity ?? 999}
                value={quantity}
                onChange={(e) => setQuantity(Number(e.target.value))}
                className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm"
              />
              {selectedShelf?.max_capacity != null && (
                <span className="mt-1 block text-[10px] text-neutral-500">
                  Shelf capacity: {selectedShelf.max_capacity}
                </span>
              )}
            </label>

            {/* Expiry */}
            <label className="block text-xs font-medium text-neutral-700">
              Expiry date
              <input
                type="date"
                min={minExpiry}
                max={maxExpiry}
                value={expiry}
                onChange={(e) => setExpiry(e.target.value)}
                className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm"
              />
            </label>

            {/* Notes */}
            <label className="block text-xs font-medium text-neutral-700">
              Notes (optional)
              <textarea
                rows={2}
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="Anything the WH manager should know"
                className="mt-1 w-full resize-none rounded-lg border border-neutral-300 px-3 py-2 text-sm"
              />
            </label>

            {submitError && (
              <p className="rounded-lg border border-red-300 bg-red-50 px-3 py-2 text-xs text-red-700">
                {submitError}
              </p>
            )}

            <div className="flex gap-2 pt-2">
              <button
                type="button"
                onClick={onClose}
                className="flex-1 rounded-lg border border-neutral-300 px-4 py-2 text-sm font-medium text-neutral-700"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleSubmit}
                disabled={!formValid || submitting}
                className="flex-1 rounded-lg bg-neutral-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
              >
                {submitting ? "Submitting..." : "Submit for review"}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
