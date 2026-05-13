"use client";

export const dynamic = "force-dynamic";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "@/app/(field)/components/field-header";

const ADMIN_ROLES = ["operator_admin", "superadmin", "manager", "warehouse"];

type FilterTab = "all" | "Active" | "Inactive" | "Onboarding";

interface Supplier {
  supplier_id: string;
  supplier_name: string;
  supplier_code: string | null;
  supplier_acronym: string | null;
  status: string | null;
  contact_person: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  address: string | null;
  country: string | null;
  category: string | null;
  products_supplied: string | null;
  payment_terms: string | null;
  payment_type: string | null;
  currency: string | null;
  return_options: boolean | null;
  rating: number | null;
  bank_details: string | null;
  contract_start_date: string | null;
  contract_end_date: string | null;
  notes: string | null;
  procurement_type: string;
  updated_at: string | null;
}

type SupplierDraft = Omit<Supplier, "supplier_id">;

const EMPTY_DRAFT: SupplierDraft = {
  supplier_name: "",
  supplier_code: "",
  supplier_acronym: "",
  status: "Active",
  contact_person: "",
  contact_email: "",
  contact_phone: "",
  address: "",
  country: "UAE",
  category: "",
  products_supplied: "",
  payment_terms: "",
  payment_type: "",
  currency: "AED",
  return_options: false,
  rating: null,
  bank_details: "",
  contract_start_date: "",
  contract_end_date: "",
  notes: "",
  procurement_type: "supplier_delivered",
  updated_at: null,
};

function generateCode(existing: Supplier[]): string {
  const used = new Set(
    existing
      .map((s) => s.supplier_code ?? "")
      .filter((c) => /^SUP_\d{3}$/.test(c))
      .map((c) => parseInt(c.slice(4), 10)),
  );
  let n = 1;
  while (used.has(n)) n++;
  return `SUP_${String(n).padStart(3, "0")}`;
}

export default function SuppliersPage() {
  const router = useRouter();

  const [loading, setLoading] = useState(true);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [filter, setFilter] = useState<FilterTab>("all");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<Record<string, SupplierDraft>>({});
  const [saving, setSaving] = useState<Record<string, boolean>>({});
  const [saveMsg, setSaveMsg] = useState<Record<string, string>>({});

  const [showAdd, setShowAdd] = useState(false);
  const [newDraft, setNewDraft] = useState<SupplierDraft>(EMPTY_DRAFT);
  const [adding, setAdding] = useState(false);
  const [addError, setAddError] = useState("");

  useEffect(() => {
    async function init() {
      const supabase = createClient();
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (!user) {
        router.replace("/login");
        return;
      }
      const { data: profile } = await supabase
        .from("user_profiles")
        .select("role")
        .eq("id", user.id)
        .single();
      if (!profile || !ADMIN_ROLES.includes(profile.role)) {
        router.replace("/field");
        return;
      }
      await load();
    }
    init();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function load() {
    setLoading(true);
    const supabase = createClient();
    const { data } = await supabase
      .from("suppliers")
      .select("*")
      .order("supplier_name");
    setSuppliers((data as Supplier[]) ?? []);
    setLoading(false);
  }

  function openRow(s: Supplier) {
    if (expandedId === s.supplier_id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(s.supplier_id);
    setDrafts((prev) => ({
      ...prev,
      [s.supplier_id]: {
        supplier_name: s.supplier_name ?? "",
        supplier_code: s.supplier_code ?? "",
        supplier_acronym: s.supplier_acronym ?? "",
        status: s.status ?? "Active",
        contact_person: s.contact_person ?? "",
        contact_email: s.contact_email ?? "",
        contact_phone: s.contact_phone ?? "",
        address: s.address ?? "",
        country: s.country ?? "UAE",
        category: s.category ?? "",
        products_supplied: s.products_supplied ?? "",
        payment_terms: s.payment_terms ?? "",
        payment_type: s.payment_type ?? "",
        currency: s.currency ?? "AED",
        return_options: s.return_options ?? false,
        rating: s.rating ?? null,
        bank_details: s.bank_details ?? "",
        contract_start_date: s.contract_start_date ?? "",
        contract_end_date: s.contract_end_date ?? "",
        notes: s.notes ?? "",
        procurement_type: s.procurement_type ?? "supplier_delivered",
        updated_at: null,
      },
    }));
  }

  function patchDraft(id: string, patch: Partial<SupplierDraft>) {
    setDrafts((prev) => ({ ...prev, [id]: { ...prev[id], ...patch } }));
  }

  async function save(id: string) {
    const draft = drafts[id];
    if (!draft) return;
    setSaving((prev) => ({ ...prev, [id]: true }));
    setSaveMsg((prev) => ({ ...prev, [id]: "" }));
    const supabase = createClient();
    const payload = {
      ...draft,
      rating: draft.rating !== null ? Number(draft.rating) : null,
      updated_at: new Date().toISOString(),
    };
    const { error } = await supabase
      .from("suppliers")
      .update(payload)
      .eq("supplier_id", id);
    setSaving((prev) => ({ ...prev, [id]: false }));
    if (error) {
      setSaveMsg((prev) => ({ ...prev, [id]: `Error: ${error.message}` }));
    } else {
      setSaveMsg((prev) => ({ ...prev, [id]: "Saved ✓" }));
      setSuppliers((prev) =>
        prev.map((s) => (s.supplier_id === id ? { ...s, ...payload } : s)),
      );
      setTimeout(() => setSaveMsg((prev) => ({ ...prev, [id]: "" })), 2000);
    }
  }

  async function addNew() {
    if (!newDraft.supplier_name.trim()) {
      setAddError("Name is required");
      return;
    }
    setAdding(true);
    setAddError("");
    const supabase = createClient();
    const code =
      newDraft.supplier_code?.trim() || generateCode(suppliers);
    const payload = {
      ...newDraft,
      supplier_code: code,
      rating: newDraft.rating !== null ? Number(newDraft.rating) : null,
      updated_at: new Date().toISOString(),
    };
    const { error } = await supabase.from("suppliers").insert([payload]);
    setAdding(false);
    if (error) {
      setAddError(error.message);
      return;
    }
    setShowAdd(false);
    setNewDraft(EMPTY_DRAFT);
    await load();
  }

  const filtered = suppliers.filter((s) => {
    if (filter === "all") return true;
    return (s.status ?? "Active") === filter;
  });

  const STATUS_COLORS: Record<string, string> = {
    Active:
      "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
    Inactive:
      "bg-neutral-100 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400",
    Onboarding:
      "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400",
  };

  const FILTER_TABS: FilterTab[] = ["all", "Active", "Inactive", "Onboarding"];

  function FieldGroup({
    label,
    children,
  }: {
    label: string;
    children: React.ReactNode;
  }) {
    return (
      <div className="mt-3">
        <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-neutral-400">
          {label}
        </p>
        <div className="space-y-2">{children}</div>
      </div>
    );
  }

  function Field({
    label,
    children,
  }: {
    label: string;
    children: React.ReactNode;
  }) {
    return (
      <div>
        <label className="mb-0.5 block text-xs text-neutral-500 dark:text-neutral-400">
          {label}
        </label>
        {children}
      </div>
    );
  }

  const inputCls =
    "w-full rounded-lg border border-neutral-200 bg-white px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-900";

  function SupplierForm({
    draft,
    onChange,
  }: {
    draft: SupplierDraft;
    onChange: (patch: Partial<SupplierDraft>) => void;
  }) {
    return (
      <div className="space-y-1">
        <FieldGroup label="Identity">
          <Field label="Supplier Name *">
            <input
              className={inputCls}
              value={draft.supplier_name}
              onChange={(e) => onChange({ supplier_name: e.target.value })}
            />
          </Field>
          <Field label="Supplier Code">
            <input
              className={inputCls}
              placeholder="Auto-generated if blank"
              value={draft.supplier_code ?? ""}
              onChange={(e) => onChange({ supplier_code: e.target.value })}
            />
          </Field>
          <Field label="Status">
            <select
              className={inputCls}
              value={draft.status ?? "Active"}
              onChange={(e) => onChange({ status: e.target.value })}
            >
              <option value="Active">Active</option>
              <option value="Inactive">Inactive</option>
              <option value="Onboarding">Onboarding</option>
              <option value="Suspended">Suspended</option>
            </select>
          </Field>
          <Field label="Acronym">
            <input
              className={inputCls}
              value={draft.supplier_acronym ?? ""}
              onChange={(e) => onChange({ supplier_acronym: e.target.value })}
            />
          </Field>
          <Field label="Procurement Type">
            <select
              className={inputCls}
              value={draft.procurement_type ?? "supplier_delivered"}
              onChange={(e) => onChange({ procurement_type: e.target.value })}
            >
              <option value="supplier_delivered">Supplier delivered</option>
              <option value="walk_in">Walk-in</option>
            </select>
          </Field>
        </FieldGroup>

        <FieldGroup label="Contact">
          <Field label="Contact Person">
            <input
              className={inputCls}
              value={draft.contact_person ?? ""}
              onChange={(e) => onChange({ contact_person: e.target.value })}
            />
          </Field>
          <Field label="Email">
            <input
              className={inputCls}
              type="email"
              value={draft.contact_email ?? ""}
              onChange={(e) => onChange({ contact_email: e.target.value })}
            />
          </Field>
          <Field label="Phone">
            <input
              className={inputCls}
              type="tel"
              value={draft.contact_phone ?? ""}
              onChange={(e) => onChange({ contact_phone: e.target.value })}
            />
          </Field>
          <Field label="Address">
            <textarea
              className={inputCls}
              rows={2}
              value={draft.address ?? ""}
              onChange={(e) => onChange({ address: e.target.value })}
            />
          </Field>
          <Field label="Country">
            <input
              className={inputCls}
              value={draft.country ?? ""}
              onChange={(e) => onChange({ country: e.target.value })}
            />
          </Field>
        </FieldGroup>

        <FieldGroup label="Catalog">
          <Field label="Category">
            <input
              className={inputCls}
              value={draft.category ?? ""}
              onChange={(e) => onChange({ category: e.target.value })}
            />
          </Field>
          <Field label="Products Supplied">
            <textarea
              className={inputCls}
              rows={2}
              value={draft.products_supplied ?? ""}
              onChange={(e) => onChange({ products_supplied: e.target.value })}
            />
          </Field>
        </FieldGroup>

        <FieldGroup label="Commercial">
          <Field label="Payment Terms">
            <input
              className={inputCls}
              placeholder="e.g. Net 30"
              value={draft.payment_terms ?? ""}
              onChange={(e) => onChange({ payment_terms: e.target.value })}
            />
          </Field>
          <Field label="Payment Type">
            <select
              className={inputCls}
              value={draft.payment_type ?? ""}
              onChange={(e) => onChange({ payment_type: e.target.value })}
            >
              <option value="">— select —</option>
              <option value="bank_transfer">Bank Transfer</option>
              <option value="cheque">Cheque</option>
              <option value="cash">Cash</option>
              <option value="credit_card">Credit Card</option>
              <option value="other">Other</option>
            </select>
          </Field>
          <Field label="Currency">
            <select
              className={inputCls}
              value={draft.currency ?? "AED"}
              onChange={(e) => onChange({ currency: e.target.value })}
            >
              <option value="AED">AED</option>
              <option value="USD">USD</option>
              <option value="EUR">EUR</option>
              <option value="GBP">GBP</option>
              <option value="INR">INR</option>
            </select>
          </Field>
          <Field label="Return Options">
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={draft.return_options ?? false}
                onChange={(e) => onChange({ return_options: e.target.checked })}
              />
              Accepts returns
            </label>
          </Field>
          <Field label="Rating (1–5)">
            <input
              className={inputCls}
              type="number"
              min={1}
              max={5}
              step={0.1}
              value={draft.rating ?? ""}
              onChange={(e) =>
                onChange({
                  rating: e.target.value ? Number(e.target.value) : null,
                })
              }
            />
          </Field>
          <Field label="Bank Details">
            <textarea
              className={inputCls}
              rows={2}
              value={draft.bank_details ?? ""}
              onChange={(e) => onChange({ bank_details: e.target.value })}
            />
          </Field>
        </FieldGroup>

        <FieldGroup label="Contract">
          <Field label="Contract Start">
            <input
              className={inputCls}
              type="date"
              value={draft.contract_start_date ?? ""}
              onChange={(e) =>
                onChange({ contract_start_date: e.target.value })
              }
            />
          </Field>
          <Field label="Contract End">
            <input
              className={inputCls}
              type="date"
              value={draft.contract_end_date ?? ""}
              onChange={(e) => onChange({ contract_end_date: e.target.value })}
            />
          </Field>
          <Field label="Notes">
            <textarea
              className={inputCls}
              rows={3}
              value={draft.notes ?? ""}
              onChange={(e) => onChange({ notes: e.target.value })}
            />
          </Field>
        </FieldGroup>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="flex min-h-screen flex-col bg-neutral-50 dark:bg-neutral-950">
        <FieldHeader title="Suppliers" />
        <div className="flex flex-1 items-center justify-center text-sm text-neutral-400">
          Loading…
        </div>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen flex-col bg-neutral-50 dark:bg-neutral-950">
      <FieldHeader
        title="Suppliers"
        rightAction={
          <button
            onClick={() => {
              setShowAdd(true);
              setNewDraft({ ...EMPTY_DRAFT });
            }}
            className="text-sm font-medium text-blue-600 dark:text-blue-400"
          >
            + Add
          </button>
        }
      />

      {/* Filter pills */}
      <div className="flex gap-2 overflow-x-auto px-4 py-3">
        {FILTER_TABS.map((tab) => (
          <button
            key={tab}
            onClick={() => setFilter(tab)}
            className={`shrink-0 rounded-full px-3 py-1 text-xs font-medium capitalize ${
              filter === tab
                ? "bg-blue-600 text-white"
                : "bg-white text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300"
            }`}
          >
            {tab}
          </button>
        ))}
      </div>

      <div className="flex-1 space-y-2 px-4 pb-8">
        {filtered.length === 0 && (
          <p className="py-8 text-center text-sm text-neutral-400">
            No suppliers
          </p>
        )}

        {filtered.map((s) => {
          const isOpen = expandedId === s.supplier_id;
          const draft = drafts[s.supplier_id];
          const statusKey = s.status ?? "Active";
          const statusColor =
            STATUS_COLORS[statusKey] ?? STATUS_COLORS.Active;

          return (
            <div
              key={s.supplier_id}
              className="overflow-hidden rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-900"
            >
              {/* Row header */}
              <button
                className="flex w-full items-center justify-between px-4 py-3 text-left"
                onClick={() => openRow(s)}
              >
                <div>
                  <p className="text-sm font-semibold">{s.supplier_name}</p>
                  <p className="text-xs text-neutral-400">
                    {s.supplier_code ?? "—"}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <span
                    className={`rounded-full px-2 py-0.5 text-xs font-medium capitalize ${statusColor}`}
                  >
                    {s.status ?? "Active"}
                  </span>
                  <span className="text-neutral-400">{isOpen ? "▲" : "▼"}</span>
                </div>
              </button>

              {/* Expanded edit */}
              {isOpen && draft && (
                <div className="border-t border-neutral-100 px-4 pb-4 pt-2 dark:border-neutral-800">
                  <SupplierForm
                    draft={draft}
                    onChange={(patch) => patchDraft(s.supplier_id, patch)}
                  />

                  {saveMsg[s.supplier_id] && (
                    <p
                      className={`mt-3 text-sm ${saveMsg[s.supplier_id].startsWith("Error") ? "text-red-500" : "text-green-600"}`}
                    >
                      {saveMsg[s.supplier_id]}
                    </p>
                  )}

                  <button
                    disabled={saving[s.supplier_id]}
                    onClick={() => save(s.supplier_id)}
                    className="mt-3 w-full rounded-xl bg-blue-600 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
                  >
                    {saving[s.supplier_id] ? "Saving…" : "Save Changes"}
                  </button>
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Add bottom sheet */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/40">
          <div className="max-h-[90vh] overflow-y-auto rounded-t-2xl bg-white px-4 pb-8 pt-4 dark:bg-neutral-900">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-base font-semibold">New Supplier</h2>
              <button
                onClick={() => setShowAdd(false)}
                className="text-neutral-400"
              >
                ✕
              </button>
            </div>

            <SupplierForm
              draft={newDraft}
              onChange={(patch) =>
                setNewDraft((prev) => ({ ...prev, ...patch }))
              }
            />

            {addError && (
              <p className="mt-3 text-sm text-red-500">{addError}</p>
            )}

            <button
              disabled={adding}
              onClick={addNew}
              className="mt-4 w-full rounded-xl bg-blue-600 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
            >
              {adding ? "Adding…" : "Add Supplier"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
