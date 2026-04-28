"use client";

export const dynamic = "force-dynamic";

import { useEffect, useState, useCallback, useMemo } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../../components/field-header";

const ADMIN_ROLES = ["operator_admin", "superadmin", "manager", "warehouse"];

const SOURCING_CHANNELS = [
  "Union Coop",
  "Amazon",
  "Supplier CF",
  "Supplier FH",
  "Supplier MG",
  "Supplier TD",
  "Arab Sweet, Jaleel",
  "Arab Sweet, Union Coop, Jaleel",
  "Leb",
  "Other",
];

interface BoonzProduct {
  product_id: string;
  boonz_product_name: string;
  product_brand: string | null;
  product_sub_brand: string | null;
  product_category: string | null;
  category_group: string | null;
  physical_type: string | null;
  product_weight_g: number | null;
  actual_weight_g: number | null;
  description: string | null;
  attr_healthy: boolean | null;
  attr_drink: boolean | null;
  attr_salty: boolean | null;
  attr_sweet: boolean | null;
  attr_30days: boolean | null;
  min_cost: number | null;
  max_cost: number | null;
  avg_cost: number | null;
  sourcing_channel: string | null;
  storage_temp_requirement: string;
}

interface ProductDraft {
  product_brand: string;
  product_sub_brand: string;
  product_category: string;
  category_group: string;
  product_weight_g: string;
  actual_weight_g: string;
  description: string;
  attr_healthy: boolean;
  attr_drink: boolean;
  attr_salty: boolean;
  attr_sweet: boolean;
  attr_30days: boolean;
  min_cost: string;
  max_cost: string;
  avg_cost: string;
  sourcing_channel: string;
  storage_temp_requirement: string;
}

const STORAGE_TEMP_OPTIONS: { value: string; label: string; desc: string }[] = [
  {
    value: "ambient",
    label: "Ambient",
    desc: "Can be staged in WH_MM / WH_MCC",
  },
  {
    value: "cold",
    label: "Cold ❄",
    desc: "Requires refrigeration — ships from WH Central only",
  },
  {
    value: "frozen",
    label: "Frozen",
    desc: "Requires freezer — ships from WH Central only",
  },
];

function rowToDraft(r: BoonzProduct): ProductDraft {
  return {
    product_brand: r.product_brand ?? "",
    product_sub_brand: r.product_sub_brand ?? "",
    product_category: r.product_category ?? "",
    category_group: r.category_group ?? "",
    product_weight_g: r.product_weight_g?.toString() ?? "",
    actual_weight_g: r.actual_weight_g?.toString() ?? "",
    description: r.description ?? "",
    attr_healthy: !!r.attr_healthy,
    attr_drink: !!r.attr_drink,
    attr_salty: !!r.attr_salty,
    attr_sweet: !!r.attr_sweet,
    attr_30days: !!r.attr_30days,
    min_cost: r.min_cost?.toString() ?? "",
    max_cost: r.max_cost?.toString() ?? "",
    avg_cost: r.avg_cost?.toString() ?? "",
    sourcing_channel: r.sourcing_channel ?? "",
    storage_temp_requirement: r.storage_temp_requirement ?? "ambient",
  };
}

function emptyDraft(): ProductDraft {
  return {
    product_brand: "",
    product_sub_brand: "",
    product_category: "",
    category_group: "",
    product_weight_g: "",
    actual_weight_g: "",
    description: "",
    attr_healthy: false,
    attr_drink: false,
    attr_salty: false,
    attr_sweet: false,
    attr_30days: false,
    min_cost: "",
    max_cost: "",
    avg_cost: "",
    sourcing_channel: "",
    storage_temp_requirement: "ambient",
  };
}

type SortOption = "name" | "category" | "brand";
type TempFilter = "all" | "cold" | "frozen";

function ToggleChip({
  label,
  value,
  onChange,
}: {
  label: string;
  value: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <button
      type="button"
      onClick={() => onChange(!value)}
      className={`rounded-full px-3 py-1 text-xs font-medium transition-colors ${
        value
          ? "bg-blue-600 text-white"
          : "bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400"
      }`}
    >
      {label}
    </button>
  );
}

function ProductForm({
  draft,
  onChange,
  categories,
  categoryGroups,
}: {
  draft: ProductDraft;
  onChange: (patch: Partial<ProductDraft>) => void;
  categories: string[];
  categoryGroups: string[];
}) {
  return (
    <div className="space-y-4">
      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">
          Identity
        </p>
        <div className="space-y-2">
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-500">
                Brand *
              </label>
              <input
                type="text"
                value={draft.product_brand}
                onChange={(e) => onChange({ product_brand: e.target.value })}
                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
              />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-500">
                Sub-brand *
              </label>
              <input
                type="text"
                value={draft.product_sub_brand}
                onChange={(e) =>
                  onChange({ product_sub_brand: e.target.value })
                }
                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
              />
            </div>
          </div>
          <div>
            <p className="mb-1 text-xs font-medium text-neutral-500">
              Product name
            </p>
            {draft.product_brand.trim() && draft.product_sub_brand.trim() ? (
              <p className="rounded-lg bg-gray-50 px-3 py-2 text-base font-bold text-gray-900 dark:bg-neutral-800 dark:text-neutral-100">
                {draft.product_brand.trim()} - {draft.product_sub_brand.trim()}
              </p>
            ) : (
              <p className="rounded-lg bg-gray-50 px-3 py-2 text-sm italic text-gray-400 dark:bg-neutral-800">
                Fill in Brand and Sub-brand above
              </p>
            )}
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-500">
                Category
              </label>
              <input
                type="text"
                list="bp-categories"
                value={draft.product_category}
                onChange={(e) => onChange({ product_category: e.target.value })}
                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
              />
              <datalist id="bp-categories">
                {categories.map((c) => (
                  <option key={c} value={c} />
                ))}
              </datalist>
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-500">
                Category Group
              </label>
              <input
                type="text"
                list="bp-category-groups"
                value={draft.category_group}
                onChange={(e) => onChange({ category_group: e.target.value })}
                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
              />
              <datalist id="bp-category-groups">
                {categoryGroups.map((c) => (
                  <option key={c} value={c} />
                ))}
              </datalist>
            </div>
          </div>
        </div>
      </div>

      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">
          Physical
        </p>
        <div className="grid grid-cols-2 gap-2">
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">
              Weight (g)
            </label>
            <input
              type="number"
              value={draft.product_weight_g}
              onChange={(e) => onChange({ product_weight_g: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">
              Actual Weight (g)
            </label>
            <input
              type="number"
              value={draft.actual_weight_g}
              onChange={(e) => onChange({ actual_weight_g: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
        </div>
        <div className="mt-2">
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Description
          </label>
          <textarea
            rows={2}
            value={draft.description}
            onChange={(e) => onChange({ description: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
      </div>

      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">
          Attributes
        </p>
        <div className="flex flex-wrap gap-2">
          <ToggleChip
            label="Healthy"
            value={draft.attr_healthy}
            onChange={(v) => onChange({ attr_healthy: v })}
          />
          <ToggleChip
            label="Drink"
            value={draft.attr_drink}
            onChange={(v) => onChange({ attr_drink: v })}
          />
          <ToggleChip
            label="Salty"
            value={draft.attr_salty}
            onChange={(v) => onChange({ attr_salty: v })}
          />
          <ToggleChip
            label="Sweet"
            value={draft.attr_sweet}
            onChange={(v) => onChange({ attr_sweet: v })}
          />
          <ToggleChip
            label="30-day shelf"
            value={draft.attr_30days}
            onChange={(v) => onChange({ attr_30days: v })}
          />
        </div>
      </div>

      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">
          Storage
        </p>
        <div className="space-y-2">
          {STORAGE_TEMP_OPTIONS.map((opt) => {
            const active = draft.storage_temp_requirement === opt.value;
            return (
              <button
                key={opt.value}
                type="button"
                onClick={() =>
                  onChange({ storage_temp_requirement: opt.value })
                }
                className={`w-full rounded-lg border px-3 py-2 text-left transition-colors ${
                  active
                    ? opt.value === "ambient"
                      ? "border-green-500 bg-green-50 dark:bg-green-900/20"
                      : opt.value === "cold"
                        ? "border-blue-500 bg-blue-50 dark:bg-blue-900/20"
                        : "border-purple-500 bg-purple-50 dark:bg-purple-900/20"
                    : "border-neutral-200 bg-white dark:border-neutral-700 dark:bg-neutral-900"
                }`}
              >
                <div className="flex items-center justify-between">
                  <span
                    className={`text-sm font-medium ${active ? "text-neutral-900 dark:text-neutral-100" : "text-neutral-600 dark:text-neutral-400"}`}
                  >
                    {opt.label}
                  </span>
                  {active && (
                    <span
                      className={`text-xs font-semibold ${
                        opt.value === "ambient"
                          ? "text-green-600"
                          : opt.value === "cold"
                            ? "text-blue-600"
                            : "text-purple-600"
                      }`}
                    >
                      ✓ Selected
                    </span>
                  )}
                </div>
                <p className="mt-0.5 text-xs text-neutral-400">{opt.desc}</p>
              </button>
            );
          })}
        </div>
      </div>

      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">
          Cost
        </p>
        <div className="grid grid-cols-3 gap-2">
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">
              Min
            </label>
            <input
              type="number"
              step="0.01"
              value={draft.min_cost}
              onChange={(e) => onChange({ min_cost: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">
              Max
            </label>
            <input
              type="number"
              step="0.01"
              value={draft.max_cost}
              onChange={(e) => onChange({ max_cost: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">
              Avg
            </label>
            <input
              type="number"
              step="0.01"
              value={draft.avg_cost}
              onChange={(e) => onChange({ avg_cost: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
        </div>
        <div className="mt-2">
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Sourcing Channel
          </label>
          {(() => {
            const isOther =
              draft.sourcing_channel === "Other" ||
              !SOURCING_CHANNELS.includes(draft.sourcing_channel);
            const selectValue = isOther ? "Other" : draft.sourcing_channel;
            return (
              <>
                <select
                  value={selectValue}
                  onChange={(e) =>
                    onChange({ sourcing_channel: e.target.value })
                  }
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                >
                  <option value="">Select channel…</option>
                  {SOURCING_CHANNELS.map((c) => (
                    <option key={c} value={c}>
                      {c}
                    </option>
                  ))}
                </select>
                {isOther && (
                  <input
                    type="text"
                    value={
                      draft.sourcing_channel === "Other"
                        ? ""
                        : draft.sourcing_channel
                    }
                    placeholder="Enter custom channel…"
                    onChange={(e) =>
                      onChange({ sourcing_channel: e.target.value || "Other" })
                    }
                    className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                  />
                )}
              </>
            );
          })()}
        </div>
      </div>
    </div>
  );
}

function draftToPayload(d: ProductDraft) {
  return {
    boonz_product_name: `${d.product_brand.trim()} - ${d.product_sub_brand.trim()}`,
    product_brand: d.product_brand.trim() || null,
    product_sub_brand: d.product_sub_brand.trim() || null,
    product_category: d.product_category.trim() || null,
    category_group: d.category_group.trim() || null,
    product_weight_g: d.product_weight_g
      ? parseFloat(d.product_weight_g)
      : null,
    actual_weight_g: d.actual_weight_g ? parseFloat(d.actual_weight_g) : null,
    description: d.description.trim() || null,
    attr_healthy: d.attr_healthy,
    attr_drink: d.attr_drink,
    attr_salty: d.attr_salty,
    attr_sweet: d.attr_sweet,
    attr_30days: d.attr_30days,
    min_cost: d.min_cost ? parseFloat(d.min_cost) : null,
    max_cost: d.max_cost ? parseFloat(d.max_cost) : null,
    avg_cost: d.avg_cost ? parseFloat(d.avg_cost) : null,
    sourcing_channel: d.sourcing_channel.trim() || null,
    storage_temp_requirement: d.storage_temp_requirement,
    updated_at: new Date().toISOString(),
  };
}

export default function BoonzProductsPage() {
  const router = useRouter();
  const [rows, setRows] = useState<BoonzProduct[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [sortBy, setSortBy] = useState<SortOption>("name");

  const [tempFilter, setTempFilter] = useState<TempFilter>("all");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<Record<string, ProductDraft>>({});
  const [saving, setSaving] = useState<Record<string, boolean>>({});
  const [saveMsg, setSaveMsg] = useState<Record<string, string>>({});

  const [showAdd, setShowAdd] = useState(false);
  const [newDraft, setNewDraft] = useState<ProductDraft>(emptyDraft());
  const [adding, setAdding] = useState(false);
  const [addError, setAddError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) {
      router.push("/login");
      return;
    }
    const { data: profile } = await supabase
      .from("user_profiles")
      .select("role")
      .eq("id", user.id)
      .single();
    if (!profile || !ADMIN_ROLES.includes(profile.role)) {
      router.push("/field");
      return;
    }

    const { data } = await supabase
      .from("boonz_products")
      .select("*")
      .order("boonz_product_name");
    if (data) setRows(data as BoonzProduct[]);
    setLoading(false);
  }, [router]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const categories = useMemo(
    () =>
      [
        ...new Set(rows.map((r) => r.product_category).filter(Boolean)),
      ].sort() as string[],
    [rows],
  );
  const categoryGroups = useMemo(
    () =>
      [
        ...new Set(rows.map((r) => r.category_group).filter(Boolean)),
      ].sort() as string[],
    [rows],
  );

  const processed = useMemo(() => {
    let r = rows;
    if (search.trim()) {
      const q = search.toLowerCase();
      r = r.filter(
        (p) =>
          p.boonz_product_name.toLowerCase().includes(q) ||
          (p.product_brand ?? "").toLowerCase().includes(q),
      );
    }
    if (tempFilter !== "all") {
      r = r.filter((p) => p.storage_temp_requirement === tempFilter);
    }
    return [...r].sort((a, b) => {
      if (sortBy === "category")
        return (a.product_category ?? "").localeCompare(
          b.product_category ?? "",
        );
      if (sortBy === "brand")
        return (a.product_brand ?? "").localeCompare(b.product_brand ?? "");
      return a.boonz_product_name.localeCompare(b.boonz_product_name);
    });
  }, [rows, search, sortBy]);

  function openEdit(row: BoonzProduct) {
    if (expandedId === row.product_id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(row.product_id);
    setDrafts((p) => ({ ...p, [row.product_id]: rowToDraft(row) }));
  }

  function patchDraft(id: string, patch: Partial<ProductDraft>) {
    setDrafts((p) => ({ ...p, [id]: { ...p[id], ...patch } }));
  }

  async function saveEdit(id: string) {
    const draft = drafts[id];
    if (
      !draft ||
      !draft.product_brand.trim() ||
      !draft.product_sub_brand.trim()
    ) {
      setSaveMsg((p) => ({
        ...p,
        [id]: "Error: Both Brand and Sub-brand are required to generate the product name",
      }));
      return;
    }
    setSaving((p) => ({ ...p, [id]: true }));
    const supabase = createClient();
    const { error } = await supabase
      .from("boonz_products")
      .update(draftToPayload(draft))
      .eq("product_id", id);
    if (error) {
      setSaveMsg((p) => ({ ...p, [id]: `Error: ${error.message}` }));
    } else {
      setSaveMsg((p) => ({ ...p, [id]: "Saved ✓" }));
      await fetchData();
      setExpandedId(null);
      setTimeout(() => setSaveMsg((p) => ({ ...p, [id]: "" })), 2000);
    }
    setSaving((p) => ({ ...p, [id]: false }));
  }

  async function handleAdd() {
    if (!newDraft.product_brand.trim() || !newDraft.product_sub_brand.trim()) {
      setAddError(
        "Both Brand and Sub-brand are required to generate the product name",
      );
      return;
    }
    const computedName = `${newDraft.product_brand.trim()} - ${newDraft.product_sub_brand.trim()}`;
    const exists = rows.some(
      (r) => r.boonz_product_name.toLowerCase() === computedName.toLowerCase(),
    );
    if (exists) {
      setAddError("A product with this name already exists");
      return;
    }
    setAdding(true);
    setAddError(null);
    const supabase = createClient();
    const { error } = await supabase
      .from("boonz_products")
      .insert(draftToPayload(newDraft));
    if (error) {
      setAddError(error.message);
      setAdding(false);
      return;
    }
    setShowAdd(false);
    setNewDraft(emptyDraft());
    await fetchData();
    setAdding(false);
  }

  const SORT_OPTIONS: { label: string; value: SortOption }[] = [
    { label: "Name A→Z", value: "name" },
    { label: "Category", value: "category" },
    { label: "Brand", value: "brand" },
  ];

  if (loading) {
    return (
      <>
        <FieldHeader title="Boonz Products" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    );
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Boonz Products"
        rightAction={
          <button
            onClick={() => {
              setNewDraft(emptyDraft());
              setShowAdd(true);
            }}
            className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
          >
            + Add
          </button>
        }
      />

      <div className="px-4 py-4">
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search by name or brand…"
          className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
        />

        <div className="mb-3 flex items-center gap-2 text-xs text-neutral-500">
          <span>Sort:</span>
          {SORT_OPTIONS.map((s) => (
            <button
              key={s.value}
              onClick={() => setSortBy(s.value)}
              className={`rounded px-2 py-1 transition-colors ${sortBy === s.value ? "bg-neutral-200 font-medium text-neutral-900 dark:bg-neutral-700 dark:text-neutral-100" : "hover:bg-neutral-100 dark:hover:bg-neutral-800"}`}
            >
              {s.label}
            </button>
          ))}
        </div>

        <div className="mb-3 flex items-center gap-2 text-xs text-neutral-500">
          <span>Storage:</span>
          {(["all", "cold", "frozen"] as TempFilter[]).map((f) => (
            <button
              key={f}
              onClick={() => setTempFilter(f)}
              className={`rounded px-2 py-1 transition-colors ${
                tempFilter === f
                  ? f === "cold"
                    ? "bg-blue-100 font-medium text-blue-700 dark:bg-blue-900/30 dark:text-blue-300"
                    : f === "frozen"
                      ? "bg-purple-100 font-medium text-purple-700 dark:bg-purple-900/30 dark:text-purple-300"
                      : "bg-neutral-200 font-medium text-neutral-900 dark:bg-neutral-700 dark:text-neutral-100"
                  : "hover:bg-neutral-100 dark:hover:bg-neutral-800"
              }`}
            >
              {f === "all" ? "All" : f === "cold" ? "❄ Cold" : "🧊 Frozen"}
            </button>
          ))}
        </div>

        <p className="mb-3 text-xs text-neutral-500">
          {processed.length} products
        </p>

        <ul className="space-y-2">
          {processed.map((row) => {
            const isExpanded = expandedId === row.product_id;
            const draft = drafts[row.product_id];

            return (
              <li
                key={row.product_id}
                className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
              >
                <div
                  className="cursor-pointer p-3"
                  onClick={() => openEdit(row)}
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-semibold truncate">
                        {row.boonz_product_name}
                      </p>
                      {row.product_brand && (
                        <p className="text-xs text-neutral-500">
                          {row.product_brand}
                        </p>
                      )}
                      <div className="mt-1 flex flex-wrap gap-1">
                        {row.product_category && (
                          <span className="rounded-full bg-blue-50 px-2 py-0.5 text-xs text-blue-700 dark:bg-blue-900/30 dark:text-blue-300">
                            {row.product_category}
                          </span>
                        )}
                        {row.category_group && (
                          <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                            {row.category_group}
                          </span>
                        )}
                        {row.storage_temp_requirement === "cold" && (
                          <span className="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-700 dark:bg-blue-900/30 dark:text-blue-300">
                            ❄ Cold
                          </span>
                        )}
                        {row.storage_temp_requirement === "frozen" && (
                          <span className="rounded-full bg-purple-100 px-2 py-0.5 text-xs font-medium text-purple-700 dark:bg-purple-900/30 dark:text-purple-300">
                            🧊 Frozen
                          </span>
                        )}
                      </div>
                    </div>
                    <div className="shrink-0 text-right">
                      {row.avg_cost != null && (
                        <p className="text-xs text-neutral-500">
                          {row.avg_cost.toFixed(2)} AED
                        </p>
                      )}
                      <span className="text-xs text-neutral-400">
                        {isExpanded ? "▲" : "▼"}
                      </span>
                    </div>
                  </div>
                </div>

                {isExpanded && draft && (
                  <div className="border-t border-neutral-100 px-3 pb-4 pt-3 dark:border-neutral-800">
                    <ProductForm
                      draft={draft}
                      onChange={(patch) => patchDraft(row.product_id, patch)}
                      categories={categories}
                      categoryGroups={categoryGroups}
                    />
                    {saveMsg[row.product_id] && (
                      <p
                        className={`mt-2 text-xs font-medium ${saveMsg[row.product_id].startsWith("Error") ? "text-red-600" : "text-green-600"}`}
                      >
                        {saveMsg[row.product_id]}
                      </p>
                    )}
                    <div className="mt-3 flex gap-2">
                      <button
                        onClick={() => saveEdit(row.product_id)}
                        disabled={saving[row.product_id]}
                        className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
                      >
                        {saving[row.product_id] ? "Saving…" : "Save"}
                      </button>
                      <button
                        onClick={() => setExpandedId(null)}
                        className="rounded-lg border border-neutral-300 px-4 py-2 text-xs font-medium text-neutral-600"
                      >
                        Cancel
                      </button>
                    </div>
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      </div>

      {showAdd && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div
            className="absolute inset-0 bg-black/50"
            onClick={() => setShowAdd(false)}
          />
          <div className="relative z-10 max-h-[90vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">
              Add Boonz Product
            </h3>
            {addError && (
              <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">
                {addError}
              </div>
            )}
            <ProductForm
              draft={newDraft}
              onChange={(patch) => setNewDraft((p) => ({ ...p, ...patch }))}
              categories={categories}
              categoryGroups={categoryGroups}
            />
            <button
              onClick={handleAdd}
              disabled={adding}
              className="mt-4 w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {adding ? "Creating…" : "Create Product"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
