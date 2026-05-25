"use client";

// PRD-012 C.1–C.5: operator-side queue for pod-add proposals on /app/inventory.
// Mirrors PendingProposalsPanel pattern. Routes approve/reject through the
// approve_pod_inventory_add / reject_pod_inventory_add canonical writers.

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface PendingAdd {
  edit_id: string;
  machine_id: string;
  machine_name: string | null;
  shelf_id: string | null;
  shelf_code: string | null;
  boonz_product_id: string;
  product_name: string | null;
  quantity: number | null;
  expiration_date: string | null;
  requested_by: string;
  requested_by_email: string | null;
  notes: string | null;
  photo_path: string | null;
  created_at: string;
}

type DialogMode = "approve" | "reject";
type DialogState = { mode: DialogMode; row: PendingAdd } | null;

const REJECT_NOTE_MIN = 10;

export default function PendingPodAdditionsPanel() {
  const supabase = useMemo(() => createClient(), []);
  const [rows, setRows] = useState<PendingAdd[]>([]);
  const [loading, setLoading] = useState(true);
  const [collapsed, setCollapsed] = useState(false);
  const [search, setSearch] = useState("");
  const [dialog, setDialog] = useState<DialogState>(null);
  const [decisionNote, setDecisionNote] = useState("");
  const [expiryOverride, setExpiryOverride] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const fetchPending = useCallback(async () => {
    const { data, error } = await supabase
      .from("pod_inventory_edits")
      .select(
        "edit_id, machine_id, destination_shelf_id, boonz_product_id, quantity_update, requested_expiration_date, requested_by, notes, photo_path, created_at, machines!pod_inventory_edits_machine_id_fkey(official_name), shelf_configurations:destination_shelf_id(shelf_code), boonz_products!inner(boonz_product_name)",
      )
      .eq("edit_type", "add_new_product")
      .eq("status", "pending")
      .order("created_at", { ascending: true })
      .limit(500);

    if (error) {
      console.error("Failed to load pending pod-adds:", error);
      setRows([]);
      setLoading(false);
      return;
    }

    type Row = {
      edit_id: string;
      machine_id: string;
      destination_shelf_id: string | null;
      boonz_product_id: string;
      quantity_update: number | null;
      requested_expiration_date: string | null;
      requested_by: string;
      notes: string | null;
      photo_path: string | null;
      created_at: string;
      machines: { official_name: string } | { official_name: string }[] | null;
      shelf_configurations:
        | { shelf_code: string }
        | { shelf_code: string }[]
        | null;
      boonz_products:
        | { boonz_product_name: string }
        | { boonz_product_name: string }[]
        | null;
    };
    const pickOne = <T,>(v: T | T[] | null | undefined): T | null =>
      Array.isArray(v) ? (v[0] ?? null) : (v ?? null);
    const list = ((data as unknown as Row[] | null) ?? []).map((r) => ({
      ...r,
      machines: pickOne(r.machines),
      shelf_configurations: pickOne(r.shelf_configurations),
      boonz_products: pickOne(r.boonz_products),
    }));

    const requesterIds = Array.from(new Set(list.map((r) => r.requested_by)));
    let emailById = new Map<string, string>();
    if (requesterIds.length > 0) {
      const { data: profiles } = await supabase
        .from("user_profiles")
        .select("id, email")
        .in("id", requesterIds);
      emailById = new Map(
        (profiles ?? []).map((p) => [
          p.id as string,
          (p.email as string) ?? "",
        ]),
      );
    }

    setRows(
      list.map((r) => ({
        edit_id: r.edit_id,
        machine_id: r.machine_id,
        machine_name: r.machines?.official_name ?? null,
        shelf_id: r.destination_shelf_id,
        shelf_code: r.shelf_configurations?.shelf_code ?? null,
        boonz_product_id: r.boonz_product_id,
        product_name: r.boonz_products?.boonz_product_name ?? null,
        quantity: r.quantity_update,
        expiration_date: r.requested_expiration_date,
        requested_by: r.requested_by,
        requested_by_email: emailById.get(r.requested_by) ?? null,
        notes: r.notes,
        photo_path: r.photo_path,
        created_at: r.created_at,
      })),
    );
    setLoading(false);
  }, [supabase]);

  useEffect(() => {
    fetchPending();
  }, [fetchPending]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter(
      (r) =>
        (r.machine_name ?? "").toLowerCase().includes(q) ||
        (r.product_name ?? "").toLowerCase().includes(q) ||
        (r.requested_by_email ?? "").toLowerCase().includes(q) ||
        (r.shelf_code ?? "").toLowerCase().includes(q),
    );
  }, [rows, search]);

  function openDialog(mode: DialogMode, row: PendingAdd) {
    setDialog({ mode, row });
    setDecisionNote("");
    setExpiryOverride(false);
    setSubmitError(null);
  }

  function closeDialog() {
    setDialog(null);
    setDecisionNote("");
    setExpiryOverride(false);
    setSubmitError(null);
  }

  async function handleSubmit() {
    if (!dialog || submitting) return;
    const { mode, row } = dialog;
    const trimmedNote = decisionNote.trim();
    if (mode === "reject" && trimmedNote.length < REJECT_NOTE_MIN) {
      setSubmitError(
        `Decision note required (minimum ${REJECT_NOTE_MIN} characters, got ${trimmedNote.length}).`,
      );
      return;
    }
    setSubmitting(true);
    setSubmitError(null);
    const fn =
      mode === "approve"
        ? "approve_pod_inventory_add"
        : "reject_pod_inventory_add";
    const args =
      mode === "approve"
        ? {
            p_edit_id: row.edit_id,
            p_decision_note: trimmedNote || null,
            p_expiry_override_accepted: expiryOverride,
          }
        : {
            p_edit_id: row.edit_id,
            p_decision_note: trimmedNote,
          };
    const { error } = await supabase.rpc(fn, args);
    setSubmitting(false);
    if (error) {
      setSubmitError(error.message ?? String(error));
      return;
    }
    closeDialog();
    fetchPending();
  }

  if (loading) {
    return (
      <div className="mb-4 rounded-xl border border-neutral-200 bg-neutral-50 p-3 text-sm text-neutral-500">
        Loading pod add-product proposals...
      </div>
    );
  }
  if (rows.length === 0) {
    return null;
  }

  return (
    <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-3">
      <button
        type="button"
        onClick={() => setCollapsed((c) => !c)}
        className="flex w-full items-center gap-2 text-left"
      >
        <span className="text-sm font-semibold text-amber-900">
          Pending Pod Additions
        </span>
        <span className="rounded-full bg-amber-500 px-2 py-0.5 text-xs font-bold text-white">
          {rows.length}
        </span>
        <span className="ml-auto text-xs text-amber-700">
          {collapsed ? "▼" : "▲"}
        </span>
      </button>

      {!collapsed && (
        <>
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Filter by machine, product, shelf, or driver email"
            className="mt-3 w-full rounded-lg border border-amber-300 px-3 py-2 text-xs"
          />
          <ul className="mt-3 space-y-2">
            {filtered.map((r) => {
              const expiryPast =
                !!r.expiration_date &&
                new Date(r.expiration_date) <=
                  new Date(new Date().toDateString());
              return (
                <li
                  key={r.edit_id}
                  className="rounded-lg border border-amber-200 bg-white p-3 text-xs"
                >
                  <div className="flex items-center justify-between">
                    <span className="font-semibold text-neutral-900">
                      {r.product_name ?? "?"} → {r.machine_name ?? "?"} /{" "}
                      {r.shelf_code ?? "?"}
                    </span>
                    <span className="text-[10px] text-neutral-500">
                      qty {r.quantity}
                    </span>
                  </div>
                  <div className="mt-1 text-neutral-600">
                    expires {r.expiration_date ?? "?"}
                    {expiryPast && (
                      <span className="ml-1 rounded bg-red-100 px-1 text-[10px] font-semibold text-red-800">
                        in past
                      </span>
                    )}{" "}
                    · submitted{" "}
                    {new Date(r.created_at).toLocaleString("en-US", {
                      month: "short",
                      day: "numeric",
                      hour: "numeric",
                      minute: "2-digit",
                    })}{" "}
                    by {r.requested_by_email ?? "(unknown)"}
                  </div>
                  {r.notes && (
                    <div className="mt-1 text-[11px] text-neutral-700">
                      Notes: {r.notes}
                    </div>
                  )}
                  <div className="mt-2 flex gap-2">
                    <button
                      type="button"
                      onClick={() => openDialog("approve", r)}
                      className="flex-1 rounded-lg bg-emerald-700 px-3 py-1.5 text-xs font-semibold text-white"
                    >
                      Approve
                    </button>
                    <button
                      type="button"
                      onClick={() => openDialog("reject", r)}
                      className="flex-1 rounded-lg border border-red-500 px-3 py-1.5 text-xs font-semibold text-red-700"
                    >
                      Reject
                    </button>
                  </div>
                </li>
              );
            })}
          </ul>
        </>
      )}

      {dialog && (
        <div
          className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center"
          onClick={closeDialog}
        >
          <div
            className="w-full max-w-md rounded-t-2xl bg-white p-4 shadow-xl sm:rounded-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="mb-3 flex items-center justify-between">
              <h3 className="text-base font-semibold">
                {dialog.mode === "approve" ? "Approve" : "Reject"} pod add
              </h3>
              <button
                type="button"
                onClick={closeDialog}
                className="text-neutral-500"
                aria-label="Close"
              >
                ✕
              </button>
            </div>
            <div className="mb-3 rounded-lg bg-neutral-100 p-2 text-xs text-neutral-800">
              <div className="font-semibold">{dialog.row.product_name}</div>
              <div className="text-neutral-600">
                {dialog.row.machine_name} / {dialog.row.shelf_code} · qty{" "}
                {dialog.row.quantity} · expires {dialog.row.expiration_date}
              </div>
            </div>

            {dialog.mode === "approve" &&
              dialog.row.expiration_date &&
              new Date(dialog.row.expiration_date) <=
                new Date(new Date().toDateString()) && (
                <label className="mb-3 flex items-start gap-2 rounded-lg border border-red-300 bg-red-50 p-2 text-xs text-red-800">
                  <input
                    type="checkbox"
                    checked={expiryOverride}
                    onChange={(e) => setExpiryOverride(e.target.checked)}
                    className="mt-0.5"
                  />
                  <span>
                    Expiry {dialog.row.expiration_date} is in the past. Check to
                    accept override.
                  </span>
                </label>
              )}

            <label className="block text-xs font-medium text-neutral-700">
              Decision note
              {dialog.mode === "reject" && (
                <span className="ml-1 text-red-700">
                  * required (min {REJECT_NOTE_MIN} chars)
                </span>
              )}
              <textarea
                rows={3}
                value={decisionNote}
                onChange={(e) => setDecisionNote(e.target.value)}
                placeholder={
                  dialog.mode === "approve"
                    ? "Optional comment for the driver"
                    : "Why is this rejected? Tell the driver."
                }
                className="mt-1 w-full resize-none rounded-lg border border-neutral-300 px-3 py-2 text-xs"
              />
            </label>

            {submitError && (
              <p className="mt-2 rounded-lg border border-red-300 bg-red-50 px-3 py-2 text-xs text-red-700">
                {submitError}
              </p>
            )}

            <div className="mt-3 flex gap-2">
              <button
                type="button"
                onClick={closeDialog}
                disabled={submitting}
                className="flex-1 rounded-lg border border-neutral-300 px-4 py-2 text-sm font-medium text-neutral-700"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleSubmit}
                disabled={submitting}
                className={`flex-1 rounded-lg px-4 py-2 text-sm font-medium text-white disabled:opacity-50 ${
                  dialog.mode === "approve" ? "bg-emerald-700" : "bg-red-700"
                }`}
              >
                {submitting
                  ? "Submitting..."
                  : dialog.mode === "approve"
                    ? "Confirm approve"
                    : "Confirm reject"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
