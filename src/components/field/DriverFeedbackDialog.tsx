"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface ProductOption {
  product_id: string;
  name: string;
}

interface Props {
  machineId: string;
  machineName?: string;
  defaultSlotCode?: string | null;
  open: boolean;
  onClose: () => void;
  onSaved?: () => void;
}

type SignalSource = "observation" | "customer_request" | "sale_anomaly";
type Direction = "" | "more" | "fewer" | "replace";

/**
 * PRD-009 acceptance criterion #2: driver app captures notes per shelf and
 * per machine at end-of-visit. Writes directly to `driver_feedback_notes`
 * (the table allows authenticated INSERT via the dfn_insert_self policy).
 *
 * Granularity per PRD Decisions:
 *   - slot_code optional (NULL = machine-level note)
 *   - boonz_product_id optional (NULL = general note like "venue busy at 3pm")
 *   - confidence 1..3 (1=just noticed, 2=seen multiple times, 3=customer asked)
 *   - signal_source default 'observation' — driver bumps to 3x weight by selecting
 *     'customer_request', or 2x by selecting 'sale_anomaly'.
 *
 * Application-side dedup: refuses to insert if the same driver submitted the
 * same note_text within the last 60s (per PRD edge case).
 */
export default function DriverFeedbackDialog({
  machineId,
  machineName,
  defaultSlotCode,
  open,
  onClose,
  onSaved,
}: Props) {
  const [products, setProducts] = useState<ProductOption[]>([]);
  const [productId, setProductId] = useState<string>("");
  const [slotCode, setSlotCode] = useState<string>(defaultSlotCode ?? "");
  const [direction, setDirection] = useState<Direction>("");
  const [signalSource, setSignalSource] = useState<SignalSource>("observation");
  const [confidence, setConfidence] = useState<number>(1);
  const [noteText, setNoteText] = useState<string>("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadProducts = useCallback(async () => {
    const supabase = createClient();
    const { data } = await supabase
      .from("boonz_products")
      .select("product_id,name")
      .limit(10000)
      .order("name", { ascending: true });
    setProducts((data ?? []) as ProductOption[]);
  }, []);

  useEffect(() => {
    if (open) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- product list bootstrap on open
      void loadProducts();
    }
  }, [open, loadProducts]);

  if (!open) return null;

  async function handleSave() {
    setError(null);
    const trimmed = noteText.trim();
    if (trimmed.length === 0) {
      setError("Note text is required.");
      return;
    }
    setSaving(true);
    const supabase = createClient();

    const {
      data: { user },
    } = await supabase.auth.getUser();
    const createdBy = user?.id ?? null;

    // Dedup window: same driver, same text in last 60s.
    if (createdBy) {
      const sixtySecondsAgo = new Date(Date.now() - 60_000).toISOString();
      const { data: recent } = await supabase
        .from("driver_feedback_notes")
        .select("feedback_id")
        .eq("created_by", createdBy)
        .eq("note_text", trimmed)
        .gte("created_at", sixtySecondsAgo)
        .limit(1);
      if (recent && recent.length > 0) {
        setSaving(false);
        setError("Duplicate of a note you just saved (60s window). Skipped.");
        return;
      }
    }

    const { error: insertError } = await supabase
      .from("driver_feedback_notes")
      .insert({
        machine_id: machineId,
        slot_code: slotCode.trim() === "" ? null : slotCode.trim(),
        boonz_product_id: productId === "" ? null : productId,
        direction: direction === "" ? null : direction,
        signal_source: signalSource,
        confidence,
        note_text: trimmed,
        created_by: createdBy,
      });

    setSaving(false);
    if (insertError) {
      setError(insertError.message);
      return;
    }

    setNoteText("");
    setProductId("");
    setDirection("");
    setSignalSource("observation");
    setConfidence(1);
    onSaved?.();
    onClose();
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-3 sm:items-center">
      <div className="w-full max-w-md rounded-lg border border-neutral-300 bg-white shadow-xl dark:border-neutral-700 dark:bg-neutral-900">
        <div className="border-b border-neutral-200 px-4 py-3 dark:border-neutral-800">
          <h2 className="text-base font-semibold">Add feedback</h2>
          {machineName && (
            <p className="mt-0.5 text-xs text-neutral-500">
              {machineName}
              {slotCode ? ` · slot ${slotCode}` : " · machine-level note"}
            </p>
          )}
        </div>

        <div className="space-y-3 px-4 py-3 text-sm">
          <label className="block">
            <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
              Slot (optional — blank for whole-machine)
            </span>
            <input
              type="text"
              value={slotCode}
              onChange={(e) => setSlotCode(e.target.value)}
              className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-700 dark:bg-neutral-950"
              placeholder="e.g. A12"
            />
          </label>

          <label className="block">
            <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
              Product (optional)
            </span>
            <select
              value={productId}
              onChange={(e) => setProductId(e.target.value)}
              className="mt-1 w-full rounded border border-neutral-300 bg-white px-2 py-1.5 text-sm dark:border-neutral-700 dark:bg-neutral-950"
            >
              <option value="">— general note —</option>
              {products.map((p) => (
                <option key={p.product_id} value={p.product_id}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>

          <div className="flex gap-2">
            <label className="flex-1">
              <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
                Direction
              </span>
              <select
                value={direction}
                onChange={(e) => setDirection(e.target.value as Direction)}
                className="mt-1 w-full rounded border border-neutral-300 bg-white px-2 py-1.5 text-sm dark:border-neutral-700 dark:bg-neutral-950"
              >
                <option value="">—</option>
                <option value="more">more</option>
                <option value="fewer">fewer</option>
                <option value="replace">replace</option>
              </select>
            </label>

            <label className="flex-1">
              <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
                Source
              </span>
              <select
                value={signalSource}
                onChange={(e) =>
                  setSignalSource(e.target.value as SignalSource)
                }
                className="mt-1 w-full rounded border border-neutral-300 bg-white px-2 py-1.5 text-sm dark:border-neutral-700 dark:bg-neutral-950"
              >
                <option value="observation">observation</option>
                <option value="customer_request">customer request</option>
                <option value="sale_anomaly">sale anomaly</option>
              </select>
            </label>
          </div>

          <div>
            <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
              Confidence
            </span>
            <div className="mt-1 flex gap-2">
              {[1, 2, 3].map((n) => (
                <button
                  key={n}
                  type="button"
                  onClick={() => setConfidence(n)}
                  className={`flex-1 rounded border px-3 py-1.5 text-xs ${
                    confidence === n
                      ? "border-sky-600 bg-sky-100 font-semibold text-sky-900 dark:border-sky-400 dark:bg-sky-900 dark:text-sky-100"
                      : "border-neutral-300 dark:border-neutral-700"
                  }`}
                >
                  {n === 1 && "1 · just noticed"}
                  {n === 2 && "2 · seen often"}
                  {n === 3 && "3 · customer asked"}
                </button>
              ))}
            </div>
          </div>

          <label className="block">
            <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
              Note
            </span>
            <textarea
              value={noteText}
              onChange={(e) => setNoteText(e.target.value)}
              rows={3}
              className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-700 dark:bg-neutral-950"
              placeholder="e.g. customers keep asking for KitKat in the morning"
            />
          </label>

          {error && (
            <div className="rounded bg-rose-50 px-2 py-1.5 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-300">
              {error}
            </div>
          )}
        </div>

        <div className="flex items-center justify-end gap-2 border-t border-neutral-200 bg-neutral-50 px-4 py-3 dark:border-neutral-800 dark:bg-neutral-950">
          <button
            type="button"
            onClick={onClose}
            disabled={saving}
            className="rounded border border-neutral-300 px-3 py-1.5 text-xs font-medium hover:bg-neutral-100 disabled:opacity-50 dark:border-neutral-700 dark:hover:bg-neutral-800"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving || noteText.trim() === ""}
            className="rounded bg-sky-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-sky-700 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save note"}
          </button>
        </div>
      </div>
    </div>
  );
}
