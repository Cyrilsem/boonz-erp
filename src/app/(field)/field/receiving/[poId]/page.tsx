"use client";

import { useEffect, useState, useCallback } from "react";
import { useParams, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../../components/field-header";

interface ReceiveBatch {
  batch_key: string;
  received_qty: number;
  expiry_date: string;
}

interface ReceiveLine {
  po_line_id: string;
  po_id: string;
  boonz_product_id: string;
  boonz_product_name: string;
  ordered_qty: number;
  supplier_id: string;
  price_per_unit_aed: number | null;
  purchase_date: string;
  wh_location: string;
  batches: ReceiveBatch[];
}

interface POHeader {
  po_id: string;
  supplier_name: string;
  purchase_date: string;
}

interface BoonzProduct {
  product_id: string;
  boonz_product_name: string;
  physical_type: string | null;
}

interface FieldAddition {
  addition_id: string;
  boonz_product_id: string;
  qty: number;
  price_per_unit_aed: number | null;
  status: string;
  boonz_products: { boonz_product_name: string };
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function generateKey(): string {
  return Math.random().toString(36).slice(2);
}

export default function ReceivingDetailPage() {
  const params = useParams<{ poId: string }>();
  const router = useRouter();
  const poId = decodeURIComponent(params.poId);

  const [header, setHeader] = useState<POHeader | null>(null);
  const [lines, setLines] = useState<ReceiveLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Field additions state
  const [showAddItem, setShowAddItem] = useState(false);
  const [allProducts, setAllProducts] = useState<BoonzProduct[]>([]);
  const [addSearch, setAddSearch] = useState("");
  const [selectedProduct, setSelectedProduct] = useState<BoonzProduct | null>(
    null,
  );
  const [addQty, setAddQty] = useState(1);
  const [addPrice, setAddPrice] = useState<number>(0);
  const [addSaving, setAddSaving] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [additions, setAdditions] = useState<FieldAddition[]>([]);

  const fetchData = useCallback(async () => {
    const supabase = createClient();

    const { data: poLines } = await supabase
      .from("purchase_orders")
      .select(
        `
        po_line_id,
        po_id,
        purchase_date,
        ordered_qty,
        expiry_date,
        boonz_product_id,
        supplier_id,
        price_per_unit_aed,
        boonz_products!inner(boonz_product_name),
        suppliers!inner(supplier_name)
      `,
      )
      .eq("po_id", poId)
      .is("received_date", null);

    // Fetch boonz_products + existing po_additions in parallel
    const [{ data: productsData }, { data: additionsData }] = await Promise.all(
      [
        supabase
          .from("boonz_products")
          .select("product_id, boonz_product_name, physical_type")
          .order("boonz_product_name")
          .limit(10000),
        supabase
          .from("po_additions")
          .select(
            "addition_id, boonz_product_id, qty, price_per_unit_aed, status, boonz_products(boonz_product_name)",
          )
          .eq("po_id", poId)
          .limit(10000),
      ],
    );
    setAllProducts((productsData ?? []) as unknown as BoonzProduct[]);
    setAdditions((additionsData ?? []) as unknown as FieldAddition[]);

    if (!poLines || poLines.length === 0) {
      setLines([]);
      setLoading(false);
      return;
    }

    const first = poLines[0];
    const s = first.suppliers as unknown as { supplier_name: string };
    setHeader({
      po_id: first.po_id,
      supplier_name: s.supplier_name,
      purchase_date: first.purchase_date,
    });

    const mapped: ReceiveLine[] = poLines.map((line) => {
      const p = line.boonz_products as unknown as {
        boonz_product_name: string;
      };
      return {
        po_line_id: line.po_line_id,
        po_id: line.po_id,
        boonz_product_id: line.boonz_product_id,
        boonz_product_name: p.boonz_product_name,
        ordered_qty: line.ordered_qty ?? 0,
        supplier_id: (line.supplier_id as string) ?? "",
        price_per_unit_aed: (line.price_per_unit_aed as number | null) ?? null,
        purchase_date: line.purchase_date,
        wh_location: "",
        batches: [
          {
            batch_key: generateKey(),
            received_qty: line.ordered_qty ?? 0,
            expiry_date: (line.expiry_date as string | null) ?? "",
          },
        ],
      };
    });

    mapped.sort((a, b) =>
      a.boonz_product_name.localeCompare(b.boonz_product_name),
    );
    setLines(mapped);

    // Pre-fill warehouse locations from most recent active batch per product
    const productIds = mapped.map((l) => l.boonz_product_id);
    if (productIds.length > 0) {
      const { data: locationData } = await supabase
        .from("warehouse_inventory")
        .select("boonz_product_id, wh_location")
        .in("boonz_product_id", productIds)
        .not("wh_location", "is", null)
        .eq("status", "Active")
        .order("created_at", { ascending: false });

      if (locationData) {
        const locationMap = new Map<string, string>();
        for (const row of locationData) {
          if (!locationMap.has(row.boonz_product_id) && row.wh_location) {
            locationMap.set(row.boonz_product_id, row.wh_location);
          }
        }
        setLines((prev) =>
          prev.map((l) => ({
            ...l,
            wh_location: locationMap.get(l.boonz_product_id) ?? l.wh_location,
          })),
        );
      }
    }

    setLoading(false);
  }, [poId]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  function addBatch(poLineId: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : {
              ...l,
              batches: [
                ...l.batches,
                { batch_key: generateKey(), received_qty: 0, expiry_date: "" },
              ],
            },
      ),
    );
  }

  function removeBatch(poLineId: string, batchKey: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : {
              ...l,
              batches: l.batches.filter((b) => b.batch_key !== batchKey),
            },
      ),
    );
  }

  function updateBatch(
    poLineId: string,
    batchKey: string,
    field: "received_qty" | "expiry_date",
    value: string | number,
  ) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : {
              ...l,
              batches: l.batches.map((b) =>
                b.batch_key !== batchKey ? b : { ...b, [field]: value },
              ),
            },
      ),
    );
  }

  function updateWHLocation(poLineId: string, value: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId ? l : { ...l, wh_location: value },
      ),
    );
  }

  async function handleConfirm() {
    setSubmitting(true);
    setError(null);

    const supabase = createClient();
    const today = getDubaiDate();

    for (const line of lines) {
      const activeBatches = line.batches.filter((b) => b.received_qty > 0);
      if (activeBatches.length === 0) continue;

      for (let i = 0; i < activeBatches.length; i++) {
        const batch = activeBatches[i];

        if (i === 0) {
          // Update original PO line with received date, actual qty, and expiry
          const { error: updateErr } = await supabase
            .from("purchase_orders")
            .update({
              received_date: today,
              expiry_date: batch.expiry_date || null,
              ordered_qty: batch.received_qty,
            })
            .eq("po_line_id", line.po_line_id);

          if (updateErr) {
            setError(`Failed to update PO: ${updateErr.message}`);
            setSubmitting(false);
            return;
          }
        } else {
          // Insert additional PO line for extra batches
          const { error: insertErr } = await supabase
            .from("purchase_orders")
            .insert({
              po_id: line.po_id,
              supplier_id: line.supplier_id,
              boonz_product_id: line.boonz_product_id,
              ordered_qty: batch.received_qty,
              price_per_unit_aed: line.price_per_unit_aed,
              expiry_date: batch.expiry_date || null,
              purchase_date: line.purchase_date,
              received_date: today,
            });

          if (insertErr) {
            setError(`Failed to insert batch: ${insertErr.message}`);
            setSubmitting(false);
            return;
          }
        }

        // Insert warehouse inventory row for each batch
        const { error: whErr } = await supabase
          .from("warehouse_inventory")
          .insert({
            boonz_product_id: line.boonz_product_id,
            warehouse_stock: batch.received_qty,
            expiration_date: batch.expiry_date || null,
            batch_id: `${poId}-B${i + 1}`,
            wh_location: line.wh_location || null,
            status: "Active",
            snapshot_date: today,
          });

        if (whErr) {
          setError(`Failed to create inventory: ${whErr.message}`);
          setSubmitting(false);
          return;
        }
      }
    }

    setSubmitted(true);
    setSubmitting(false);
  }

  async function handleAddConfirm() {
    if (!selectedProduct) return;
    setAddSaving(true);
    const supabase = createClient();
    const {
      data: { user: authUser },
    } = await supabase.auth.getUser();

    await supabase.from("po_additions").insert({
      po_id: poId,
      boonz_product_id: selectedProduct.product_id,
      qty: addQty,
      price_per_unit_aed: addPrice || null,
      added_by: authUser?.id,
      status: "pending_receive",
    });

    setAddSaving(false);
    setShowAddItem(false);
    setSelectedProduct(null);
    setAddSearch("");
    setAddQty(1);
    setAddPrice(0);
    setToast("Added!");
    setTimeout(() => setToast(null), 2000);
    fetchData();
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Receive Delivery" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading PO details…</p>
        </div>
      </>
    );
  }

  if (submitted) {
    return (
      <>
        <FieldHeader title="Receive Delivery" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <div className="mb-4 rounded-full bg-green-100 p-4 dark:bg-green-900">
            <span className="text-2xl">✓</span>
          </div>
          <h2 className="mb-2 text-lg font-semibold">Received ✓</h2>
          <p className="mb-4 text-sm text-neutral-500">
            {header?.po_id} has been received into inventory
          </p>
          <button
            onClick={() => router.push("/field/receiving")}
            className="rounded-lg bg-neutral-900 px-6 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            Back to receiving
          </button>
        </div>
      </>
    );
  }

  if (lines.length === 0) {
    return (
      <>
        <FieldHeader title="Receive Delivery" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No pending lines for this PO
          </p>
          <button
            onClick={() => router.back()}
            className="mt-4 text-sm text-neutral-500 hover:text-neutral-700"
          >
            ← Back
          </button>
        </div>
      </>
    );
  }

  return (
    <div className="px-4 py-4 pb-24">
      <FieldHeader title="Receive Delivery" />

      {header && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{header.po_id}</h1>
          <p className="text-sm text-neutral-500">{header.supplier_name}</p>
          <p className="text-xs text-neutral-400">
            {formatDate(header.purchase_date)}
          </p>
        </div>
      )}

      <ul className="space-y-4">
        {lines.map((line) => {
          const batchTotal = line.batches.reduce(
            (sum, b) => sum + b.received_qty,
            0,
          );
          const totalColor =
            batchTotal === line.ordered_qty
              ? "text-green-600 dark:text-green-400"
              : batchTotal > line.ordered_qty
                ? "text-red-600 dark:text-red-400"
                : "text-amber-600 dark:text-amber-400";

          return (
            <li
              key={line.po_line_id}
              className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
            >
              {/* Product header */}
              <p className="mb-1 text-sm font-bold">
                {line.boonz_product_name}
              </p>
              <p className="mb-3 text-xs text-neutral-500">
                Ordered: {line.ordered_qty} units
              </p>

              {/* Sub-batch rows */}
              <div className="space-y-3">
                {line.batches.map((batch, bIdx) => (
                  <div
                    key={batch.batch_key}
                    className="ml-2 rounded-lg border border-neutral-100 bg-neutral-50 p-3 dark:border-neutral-700 dark:bg-neutral-900"
                  >
                    <div className="mb-2 flex items-center justify-between">
                      <span className="text-xs font-semibold text-neutral-500">
                        Batch {bIdx + 1}
                      </span>
                      {line.batches.length > 1 && (
                        <button
                          onClick={() =>
                            removeBatch(line.po_line_id, batch.batch_key)
                          }
                          className="text-xs text-red-500 hover:text-red-700 dark:text-red-400"
                        >
                          × remove
                        </button>
                      )}
                    </div>

                    <div className="grid grid-cols-2 gap-2">
                      <div>
                        <label className="mb-0.5 block text-xs text-neutral-500">
                          Qty
                        </label>
                        <input
                          type="number"
                          min={0}
                          value={batch.received_qty}
                          onChange={(e) =>
                            updateBatch(
                              line.po_line_id,
                              batch.batch_key,
                              "received_qty",
                              parseFloat(e.target.value) || 0,
                            )
                          }
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800"
                        />
                      </div>
                      <div>
                        <label className="mb-0.5 block text-xs text-neutral-500">
                          Expiry date
                        </label>
                        <input
                          type="date"
                          value={batch.expiry_date}
                          onChange={(e) =>
                            updateBatch(
                              line.po_line_id,
                              batch.batch_key,
                              "expiry_date",
                              e.target.value,
                            )
                          }
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800"
                        />
                      </div>
                    </div>
                  </div>
                ))}
              </div>

              {/* Add batch button */}
              <button
                onClick={() => addBatch(line.po_line_id)}
                className="mt-2 text-xs font-medium text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
              >
                + Add expiry batch
              </button>

              {/* Running total */}
              <p className={`mt-2 text-xs font-medium ${totalColor}`}>
                {batchTotal} of {line.ordered_qty} received
              </p>

              {/* Warehouse location */}
              <div className="mt-3">
                <label className="mb-0.5 block text-xs text-neutral-500">
                  Warehouse location
                </label>
                <input
                  type="text"
                  value={line.wh_location}
                  onChange={(e) =>
                    updateWHLocation(line.po_line_id, e.target.value)
                  }
                  placeholder="e.g. A-01"
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
                />
              </div>
            </li>
          );
        })}
      </ul>

      {/* Field additions */}
      {additions.filter((a) => a.status === "pending_receive").length > 0 && (
        <div className="mt-4 space-y-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-amber-600">
            Field Additions
          </p>
          {additions
            .filter((a) => a.status === "pending_receive")
            .map((a) => (
              <div
                key={a.addition_id}
                className="flex items-center justify-between rounded-lg border border-amber-200 bg-amber-50 px-3 py-2"
              >
                <div>
                  <span className="text-sm font-medium text-amber-900">
                    {a.boonz_products.boonz_product_name}
                  </span>
                  <span className="ml-2 text-xs text-amber-600">x{a.qty}</span>
                  {a.price_per_unit_aed != null && (
                    <span className="ml-2 text-xs text-amber-600">
                      {a.price_per_unit_aed.toFixed(2)} AED
                    </span>
                  )}
                </div>
                <span className="rounded-full bg-amber-200 px-2 py-0.5 text-xs font-semibold text-amber-800">
                  Pending
                </span>
              </div>
            ))}
        </div>
      )}

      {/* Add item button */}
      <button
        onClick={() => {
          setShowAddItem(true);
          setSelectedProduct(null);
          setAddSearch("");
          setAddQty(1);
          setAddPrice(0);
        }}
        className="mt-4 w-full rounded-lg border-2 border-dashed border-blue-200 bg-blue-50 py-3 text-sm font-medium text-blue-600 transition-colors hover:bg-blue-100"
      >
        + Add item
      </button>

      {/* Bottom sheet */}
      {showAddItem && (
        <div className="fixed inset-0 z-50 flex items-end">
          <div
            className="absolute inset-0 bg-black/25"
            onClick={() => setShowAddItem(false)}
          />
          <div className="relative z-10 w-full rounded-t-2xl bg-white p-4 shadow-lg">
            <div className="mb-3 flex items-center justify-between">
              <h3 className="text-base font-bold">Add Item</h3>
              <button
                onClick={() => setShowAddItem(false)}
                className="text-lg text-neutral-400"
              >
                ✕
              </button>
            </div>

            {!selectedProduct ? (
              <>
                <input
                  type="text"
                  placeholder="Search products…"
                  value={addSearch}
                  onChange={(e) => setAddSearch(e.target.value)}
                  className="mb-2 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm outline-none"
                  autoFocus
                />
                <div className="max-h-60 overflow-y-auto">
                  {allProducts
                    .filter((p) =>
                      p.boonz_product_name
                        .toLowerCase()
                        .includes(addSearch.toLowerCase()),
                    )
                    .map((p) => (
                      <button
                        key={p.product_id}
                        onClick={() => setSelectedProduct(p)}
                        className="flex w-full items-center justify-between border-b border-neutral-100 px-2 py-2.5 text-left text-sm hover:bg-neutral-50"
                      >
                        <span>{p.boonz_product_name}</span>
                        {p.physical_type && (
                          <span className="ml-2 rounded bg-neutral-200 px-1.5 py-0.5 text-xs text-neutral-600">
                            {p.physical_type}
                          </span>
                        )}
                      </button>
                    ))}
                </div>
              </>
            ) : (
              <>
                <p className="mb-3 text-sm font-medium text-neutral-700">
                  {selectedProduct.boonz_product_name}
                </p>
                <div className="mb-3 grid grid-cols-2 gap-3">
                  <div>
                    <label className="mb-0.5 block text-xs text-neutral-500">
                      Quantity
                    </label>
                    <input
                      type="number"
                      min={1}
                      value={addQty}
                      onChange={(e) => setAddQty(Number(e.target.value) || 1)}
                      className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm"
                    />
                  </div>
                  <div>
                    <label className="mb-0.5 block text-xs text-neutral-500">
                      Price (AED)
                    </label>
                    <input
                      type="number"
                      min={0}
                      step={0.01}
                      value={addPrice || ""}
                      onChange={(e) => setAddPrice(Number(e.target.value))}
                      className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm"
                    />
                  </div>
                </div>
                <div className="flex gap-2">
                  <button
                    onClick={() => setSelectedProduct(null)}
                    className="flex-1 rounded-lg border border-neutral-300 py-2.5 text-sm font-medium text-neutral-600"
                  >
                    Back
                  </button>
                  <button
                    onClick={handleAddConfirm}
                    disabled={addSaving}
                    className="flex-1 rounded-lg bg-neutral-900 py-2.5 text-sm font-medium text-white disabled:opacity-50"
                  >
                    {addSaving ? "Saving…" : "Confirm"}
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}

      {/* Toast */}
      {toast && (
        <div className="fixed left-1/2 top-8 z-50 -translate-x-1/2 rounded-lg bg-green-600 px-4 py-2 text-sm font-medium text-white shadow-lg">
          {toast}
        </div>
      )}

      {error && (
        <p className="mt-4 text-sm text-red-600 dark:text-red-400">{error}</p>
      )}

      <div className="fixed bottom-14 left-0 right-0 border-t border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        <button
          onClick={handleConfirm}
          disabled={submitting}
          className="w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {submitting ? "Confirming…" : "Confirm receiving"}
        </button>
      </div>
    </div>
  );
}
