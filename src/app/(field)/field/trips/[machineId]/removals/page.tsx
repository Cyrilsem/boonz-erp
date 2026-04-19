"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../../../components/field-header";

interface ProductOption {
  pod_product_id: string;
  pod_product_name: string;
  boonz_product_id: string | null;
}

interface RemovalLine {
  product: ProductOption | null;
  quantity: number;
  reason: string;
}

const REASONS = ["Expired", "Damaged", "Other"];

export default function RemovalsPage() {
  const params = useParams<{ machineId: string }>();
  const router = useRouter();
  const machineId = params.machineId;

  const [products, setProducts] = useState<ProductOption[]>([]);
  const [removals, setRemovals] = useState<RemovalLine[]>([
    { product: null, quantity: 1, reason: "Expired" },
  ]);
  const [submitting, setSubmitting] = useState(false);
  const [loading, setLoading] = useState(true);
  const [machineName, setMachineName] = useState("");

  useEffect(() => {
    async function fetchProducts() {
      const supabase = createClient();

      const { data: machineData } = await supabase
        .from("machines")
        .select("official_name")
        .eq("machine_id", machineId)
        .single();

      if (machineData) setMachineName(machineData.official_name);

      const { data: podProducts } = await supabase
        .from("pod_products")
        .select("pod_product_id, pod_product_name, boonz_product_id")
        .order("pod_product_name");

      if (podProducts) {
        setProducts(podProducts);
      }
      setLoading(false);
    }

    fetchProducts();
  }, [machineId]);

  function updateRemoval(
    idx: number,
    field: keyof RemovalLine,
    value: unknown,
  ) {
    setRemovals((prev) =>
      prev.map((r, i) => (i === idx ? { ...r, [field]: value } : r)),
    );
  }

  function addLine() {
    setRemovals((prev) => [
      ...prev,
      { product: null, quantity: 1, reason: "Expired" },
    ]);
  }

  function removeLine(idx: number) {
    setRemovals((prev) => prev.filter((_, i) => i !== idx));
  }

  async function handleSubmit() {
    const validLines = removals.filter((r) => r.product && r.quantity > 0);
    if (validLines.length === 0) {
      router.back();
      return;
    }

    setSubmitting(true);
    const supabase = createClient();
    const today = getDubaiDate();

    const inserts = validLines.map((r) => ({
      machine_id: machineId,
      boonz_product_id: r.product?.boonz_product_id ?? null,
      snapshot_date: today,
      current_stock: 0,
      status: "Removed / Expired",
      removal_reason: r.reason, // BUG-5 fix: persist the reason
    }));

    await supabase.from("pod_inventory").insert(inserts);
    router.back();
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Removals" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    );
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Removals" />
      <p className="mb-4 text-sm text-neutral-500">{machineName}</p>

      <div className="space-y-3">
        {removals.map((removal, idx) => (
          <div
            key={idx}
            className="rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
          >
            <div className="mb-2 flex items-center justify-between">
              <span className="text-xs font-medium text-neutral-500">
                Item {idx + 1}
              </span>
              {removals.length > 1 && (
                <button
                  onClick={() => removeLine(idx)}
                  className="text-xs text-red-500 hover:text-red-700"
                >
                  Remove
                </button>
              )}
            </div>

            <select
              value={removal.product?.pod_product_id ?? ""}
              onChange={(e) => {
                const selected = products.find(
                  (p) => p.pod_product_id === e.target.value,
                );
                updateRemoval(idx, "product", selected ?? null);
              }}
              className="mb-2 w-full rounded border border-neutral-300 px-2 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            >
              <option value="">Select product</option>
              {products.map((p) => (
                <option key={p.pod_product_id} value={p.pod_product_id}>
                  {p.pod_product_name}
                </option>
              ))}
            </select>

            <div className="flex gap-2">
              <input
                type="number"
                min={1}
                value={removal.quantity}
                onChange={(e) =>
                  updateRemoval(idx, "quantity", parseInt(e.target.value) || 1)
                }
                className="w-20 rounded border border-neutral-300 px-2 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                placeholder="Qty"
              />
              <select
                value={removal.reason}
                onChange={(e) => updateRemoval(idx, "reason", e.target.value)}
                className="flex-1 rounded border border-neutral-300 px-2 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
              >
                {REASONS.map((r) => (
                  <option key={r} value={r}>
                    {r}
                  </option>
                ))}
              </select>
            </div>
          </div>
        ))}
      </div>

      <button
        onClick={addLine}
        className="mt-3 w-full rounded-lg border border-dashed border-neutral-300 py-2.5 text-sm text-neutral-500 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:hover:bg-neutral-900"
      >
        + Add another item
      </button>

      <div className="mt-4 flex gap-2">
        <button
          onClick={() => router.back()}
          className="flex-1 rounded-lg border border-neutral-200 py-3 text-sm font-medium transition-colors hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-900"
        >
          Nothing to remove
        </button>
        <button
          onClick={handleSubmit}
          disabled={submitting}
          className="flex-1 rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {submitting ? "Saving…" : "Submit removals"}
        </button>
      </div>
    </div>
  );
}
