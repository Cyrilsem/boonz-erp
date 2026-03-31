"use client";

export const dynamic = "force-dynamic";

import { useEffect, useState, useCallback, useMemo } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../../components/field-header";

const ADMIN_ROLES = ["operator_admin", "superadmin", "manager", "warehouse"];

type TabId = "products" | "aliases";

// ─── Product types ─────────────────────────────────────────────────────────────

interface PodProduct {
  pod_product_id: string;
  custom_code: string | null;
  pod_product_name: string;
  product_category: string | null;
  barcode: string | null;
  machine_type: string | null;
  measurement_method: string | null;
  weight_g: number | null;
  purchasing_cost: number | null;
  recommended_selling_price: number | null;
  supplier_id: string | null;
  supplier_name: string | null;
}

interface PodDraft {
  pod_product_name: string;
  product_category: string;
  barcode: string;
  machine_type: string;
  measurement_method: string;
  weight_g: string;
  purchasing_cost: string;
  recommended_selling_price: string;
  supplier_id: string;
}

interface Supplier {
  supplier_id: string;
  supplier_name: string;
}

function emptyDraft(): PodDraft {
  return {
    pod_product_name: "",
    product_category: "",
    barcode: "",
    machine_type: "",
    measurement_method: "",
    weight_g: "",
    purchasing_cost: "",
    recommended_selling_price: "",
    supplier_id: "",
  };
}

function rowToDraft(r: PodProduct): PodDraft {
  return {
    pod_product_name: r.pod_product_name,
    product_category: r.product_category ?? "",
    barcode: r.barcode ?? "",
    machine_type: r.machine_type ?? "",
    measurement_method: r.measurement_method ?? "",
    weight_g: r.weight_g?.toString() ?? "",
    purchasing_cost: r.purchasing_cost?.toString() ?? "",
    recommended_selling_price: r.recommended_selling_price?.toString() ?? "",
    supplier_id: r.supplier_id ?? "",
  };
}

function draftToPayload(d: PodDraft) {
  return {
    pod_product_name: d.pod_product_name.trim(),
    product_category: d.product_category.trim() || null,
    barcode: d.barcode.trim() || null,
    machine_type: d.machine_type.trim() || null,
    measurement_method: d.measurement_method.trim() || null,
    weight_g: d.weight_g ? parseFloat(d.weight_g) : null,
    purchasing_cost: d.purchasing_cost ? parseFloat(d.purchasing_cost) : null,
    recommended_selling_price: d.recommended_selling_price
      ? parseFloat(d.recommended_selling_price)
      : null,
    supplier_id: d.supplier_id || null,
    updated_at: new Date().toISOString(),
  };
}

function PodForm({
  draft,
  onChange,
  categories,
  suppliers,
  customCode,
}: {
  draft: PodDraft;
  onChange: (patch: Partial<PodDraft>) => void;
  categories: string[];
  suppliers: Supplier[];
  customCode: string;
}) {
  return (
    <div className="space-y-3">
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">
          Product Name *
        </label>
        <input
          type="text"
          value={draft.pod_product_name}
          onChange={(e) => onChange({ pod_product_name: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
        />
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Custom Code
          </label>
          <div className="flex items-center rounded border border-neutral-200 bg-neutral-50 px-2 py-1.5 dark:border-neutral-700 dark:bg-neutral-800">
            <span className="font-mono text-sm font-bold text-neutral-700 dark:text-neutral-300">
              {customCode || (
                <span className="italic font-normal text-neutral-400">
                  auto
                </span>
              )}
            </span>
          </div>
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Barcode
          </label>
          <input
            type="text"
            value={draft.barcode}
            onChange={(e) => onChange({ barcode: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Category
          </label>
          <input
            type="text"
            list="pod-categories"
            value={draft.product_category}
            onChange={(e) => onChange({ product_category: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
          <datalist id="pod-categories">
            {categories.map((c) => (
              <option key={c} value={c} />
            ))}
          </datalist>
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Machine Type
          </label>
          <input
            type="text"
            value={draft.machine_type}
            onChange={(e) => onChange({ machine_type: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Weight (g)
          </label>
          <input
            type="number"
            value={draft.weight_g}
            onChange={(e) => onChange({ weight_g: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Measure Method
          </label>
          <input
            type="text"
            value={draft.measurement_method}
            onChange={(e) => onChange({ measurement_method: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Purchasing Cost (AED)
          </label>
          <input
            type="number"
            step="0.01"
            value={draft.purchasing_cost}
            onChange={(e) => onChange({ purchasing_cost: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Selling Price (AED)
          </label>
          <input
            type="number"
            step="0.01"
            value={draft.recommended_selling_price}
            onChange={(e) =>
              onChange({ recommended_selling_price: e.target.value })
            }
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
      </div>
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">
          Supplier
        </label>
        <select
          value={draft.supplier_id}
          onChange={(e) => onChange({ supplier_id: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
        >
          <option value="">No supplier</option>
          {suppliers.map((s) => (
            <option key={s.supplier_id} value={s.supplier_id}>
              {s.supplier_name}
            </option>
          ))}
        </select>
      </div>
    </div>
  );
}

// ─── Alias types ───────────────────────────────────────────────────────────────

interface PodAlias {
  id: string;
  official_name: string;
  original_name: string;
  mapped_at: string | null;
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function PodProductsPage() {
  const router = useRouter();
  const [activeTab, setActiveTab] = useState<TabId>("products");

  // Products tab
  const [rows, setRows] = useState<PodProduct[]>([]);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<Record<string, PodDraft>>({});
  const [saving, setSaving] = useState<Record<string, boolean>>({});
  const [saveMsg, setSaveMsg] = useState<Record<string, string>>({});
  const [showAdd, setShowAdd] = useState(false);
  const [newDraft, setNewDraft] = useState<PodDraft>(emptyDraft());
  const [generatedCode, setGeneratedCode] = useState("");
  const [adding, setAdding] = useState(false);
  const [addError, setAddError] = useState<string | null>(null);

  // Aliases tab
  const [aliases, setAliases] = useState<PodAlias[]>([]);
  const [aliasSearch, setAliasSearch] = useState("");
  const [expandedGroup, setExpandedGroup] = useState<string | null>(null);
  const [addAliasForGroup, setAddAliasForGroup] = useState<string | null>(null);
  const [inlineAlias, setInlineAlias] = useState("");
  const [addingAlias, setAddingAlias] = useState(false);
  const [inlineAliasError, setInlineAliasError] = useState<string | null>(null);
  const [renamingGroup, setRenamingGroup] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [renameSaving, setRenameSaving] = useState(false);
  const [showAddOfficial, setShowAddOfficial] = useState(false);
  const [newOfficialName, setNewOfficialName] = useState("");
  const [newOfficialAlias, setNewOfficialAlias] = useState("");
  const [addingOfficial, setAddingOfficial] = useState(false);
  const [addOfficialError, setAddOfficialError] = useState<string | null>(null);

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

    const [{ data: podData }, { data: supplierData }, { data: aliasData }] =
      await Promise.all([
        supabase
          .from("pod_products")
          .select(
            "pod_product_id, custom_code, pod_product_name, product_category, barcode, machine_type, measurement_method, weight_g, purchasing_cost, recommended_selling_price, supplier_id, suppliers(supplier_name)",
          )
          .order("pod_product_name"),
        supabase
          .from("suppliers")
          .select("supplier_id, supplier_name")
          .eq("status", "Active")
          .order("supplier_name"),
        supabase
          .from("product_name_conventions")
          .select("id, original_name, official_name, mapped_at")
          .order("official_name", { ascending: true })
          .order("original_name", { ascending: true }),
      ]);

    if (podData) {
      setRows(
        podData.map((r) => {
          const s = r.suppliers as unknown as { supplier_name: string } | null;
          return {
            ...r,
            supplier_name: s?.supplier_name ?? null,
          } as PodProduct;
        }),
      );
    }
    if (supplierData) setSuppliers(supplierData);

    // Deduplicate by original_name within each official_name using Map
    const grouped = new Map<
      string,
      { official_name: string; aliases: PodAlias[] }
    >();
    for (const row of (aliasData ?? []) as PodAlias[]) {
      if (!grouped.has(row.official_name))
        grouped.set(row.official_name, {
          official_name: row.official_name,
          aliases: [],
        });
      const group = grouped.get(row.official_name)!;
      if (!group.aliases.find((a) => a.original_name === row.original_name)) {
        group.aliases.push(row);
      }
    }
    const deduped = Array.from(grouped.values()).flatMap((g) => g.aliases);
    console.log(
      "[PodAliases] loaded rows:",
      aliasData?.length,
      "groups:",
      grouped.size,
    );
    setAliases(deduped);
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

  const filtered = useMemo(() => {
    if (!search.trim()) return rows;
    const q = search.toLowerCase();
    return rows.filter(
      (r) =>
        r.pod_product_name.toLowerCase().includes(q) ||
        (r.custom_code ?? "").toLowerCase().includes(q),
    );
  }, [rows, search]);

  // Grouped aliases (Map-based, deduplicated by original_name within official_name)
  const aliasGroups = useMemo(() => {
    const q = aliasSearch.toLowerCase();
    const src = q
      ? aliases.filter(
          (a) =>
            a.official_name.toLowerCase().includes(q) ||
            a.original_name.toLowerCase().includes(q),
        )
      : aliases;
    const grouped = new Map<
      string,
      { official_name: string; aliases: PodAlias[] }
    >();
    for (const row of src) {
      if (!grouped.has(row.official_name))
        grouped.set(row.official_name, {
          official_name: row.official_name,
          aliases: [],
        });
      const group = grouped.get(row.official_name)!;
      if (!group.aliases.find((a) => a.original_name === row.original_name)) {
        group.aliases.push(row);
      }
    }
    return Array.from(grouped.values()).sort((a, b) =>
      a.official_name.localeCompare(b.official_name),
    );
  }, [aliases, aliasSearch]);

  // ── Products tab actions ───────────────────────────────────────────────────

  async function generateNextCode() {
    const supabase = createClient();
    const { data } = await supabase
      .from("pod_products")
      .select("custom_code")
      .like("custom_code", "PD%")
      .order("custom_code", { ascending: false })
      .limit(1);
    const last = data?.[0]?.custom_code ?? "PD000";
    const num = parseInt(last.replace(/^PD/, ""), 10) || 0;
    setGeneratedCode(`PD${String(num + 1).padStart(3, "0")}`);
  }

  function openEdit(row: PodProduct) {
    if (expandedId === row.pod_product_id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(row.pod_product_id);
    setDrafts((p) => ({ ...p, [row.pod_product_id]: rowToDraft(row) }));
  }

  async function saveEdit(id: string) {
    const draft = drafts[id];
    if (!draft || !draft.pod_product_name.trim()) return;
    setSaving((p) => ({ ...p, [id]: true }));
    const supabase = createClient();
    const { error } = await supabase
      .from("pod_products")
      .update(draftToPayload(draft))
      .eq("pod_product_id", id);
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
    if (!newDraft.pod_product_name.trim()) {
      setAddError("Product name required");
      return;
    }
    setAdding(true);
    setAddError(null);
    const supabase = createClient();
    const { error } = await supabase.from("pod_products").insert({
      ...draftToPayload(newDraft),
      custom_code: generatedCode || null,
    });
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

  // ── Aliases tab actions ────────────────────────────────────────────────────

  async function deleteAlias(id: string) {
    const supabase = createClient();
    await supabase.from("product_name_conventions").delete().eq("id", id);
    await fetchData();
  }

  async function addInlineAlias(officialName: string) {
    if (!inlineAlias.trim()) return;
    const isDupe = aliases.some(
      (a) =>
        a.official_name === officialName &&
        a.original_name.toLowerCase() === inlineAlias.trim().toLowerCase(),
    );
    if (isDupe) {
      setInlineAliasError("Already exists");
      return;
    }
    setAddingAlias(true);
    setInlineAliasError(null);
    const supabase = createClient();
    const { error } = await supabase.from("product_name_conventions").insert({
      official_name: officialName,
      original_name: inlineAlias.trim(),
    });
    if (!error) {
      setAddAliasForGroup(null);
      setInlineAlias("");
      await fetchData();
    }
    setAddingAlias(false);
  }

  async function handleRenameGroup(oldName: string) {
    if (!renameValue.trim() || renameValue.trim() === oldName) {
      setRenamingGroup(null);
      return;
    }
    setRenameSaving(true);
    const supabase = createClient();
    await supabase
      .from("product_name_conventions")
      .update({ official_name: renameValue.trim() })
      .eq("official_name", oldName);
    setRenamingGroup(null);
    setRenameValue("");
    await fetchData();
    setRenameSaving(false);
  }

  async function handleAddOfficialName() {
    if (!newOfficialName.trim()) {
      setAddOfficialError("Official name required");
      return;
    }
    const isDupe = aliases.some(
      (a) =>
        a.official_name.toLowerCase() === newOfficialName.trim().toLowerCase(),
    );
    if (isDupe) {
      setAddOfficialError("This name already exists");
      return;
    }
    setAddingOfficial(true);
    setAddOfficialError(null);
    const supabase = createClient();
    const rows: { official_name: string; original_name: string }[] = [
      {
        official_name: newOfficialName.trim(),
        original_name: newOfficialName.trim(),
      },
    ];
    if (
      newOfficialAlias.trim() &&
      newOfficialAlias.trim().toLowerCase() !==
        newOfficialName.trim().toLowerCase()
    ) {
      rows.push({
        official_name: newOfficialName.trim(),
        original_name: newOfficialAlias.trim(),
      });
    }
    const { error } = await supabase
      .from("product_name_conventions")
      .insert(rows);
    if (error) {
      setAddOfficialError(error.message);
      setAddingOfficial(false);
      return;
    }
    setShowAddOfficial(false);
    setNewOfficialName("");
    setNewOfficialAlias("");
    await fetchData();
    setAddingOfficial(false);
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Pod Products" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    );
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Pod Products"
        rightAction={
          activeTab === "products" ? (
            <button
              onClick={() => {
                setNewDraft(emptyDraft());
                generateNextCode();
                setShowAdd(true);
              }}
              className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
            >
              + Add
            </button>
          ) : (
            <button
              onClick={() => {
                setNewOfficialName("");
                setNewOfficialAlias("");
                setAddOfficialError(null);
                setShowAddOfficial(true);
              }}
              className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
            >
              + Name
            </button>
          )
        }
      />

      {/* Tabs */}
      <div className="flex border-b border-neutral-200 dark:border-neutral-800">
        {(["products", "aliases"] as TabId[]).map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            className={`flex-1 py-3 text-sm font-medium transition-colors ${
              activeTab === tab
                ? "border-b-2 border-blue-600 text-blue-600"
                : "text-neutral-500 hover:text-neutral-700"
            }`}
          >
            {tab === "aliases" ? "Pod Aliases" : "Products"}
          </button>
        ))}
      </div>

      {/* ── Products tab ── */}
      {activeTab === "products" && (
        <div className="px-4 py-4">
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search by name or code…"
            className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
          />
          <p className="mb-3 text-xs text-neutral-500">
            {filtered.length} products
          </p>

          <ul className="space-y-2">
            {filtered.map((row) => {
              const isExpanded = expandedId === row.pod_product_id;
              const draft = drafts[row.pod_product_id];
              return (
                <li
                  key={row.pod_product_id}
                  className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <div
                    className="cursor-pointer p-3"
                    onClick={() => openEdit(row)}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0 flex-1">
                        <p className="text-sm font-semibold truncate">
                          {row.pod_product_name}
                        </p>
                        {row.custom_code && (
                          <p className="font-mono text-xs text-neutral-500">
                            {row.custom_code}
                          </p>
                        )}
                        <div className="mt-1 flex flex-wrap gap-1">
                          {row.product_category && (
                            <span className="rounded-full bg-blue-50 px-2 py-0.5 text-xs text-blue-700 dark:bg-blue-900/30 dark:text-blue-300">
                              {row.product_category}
                            </span>
                          )}
                          {row.machine_type && (
                            <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                              {row.machine_type}
                            </span>
                          )}
                        </div>
                      </div>
                      <div className="shrink-0 text-right">
                        {row.recommended_selling_price != null && (
                          <p className="text-xs text-neutral-500">
                            {row.recommended_selling_price.toFixed(2)} AED
                          </p>
                        )}
                        {row.supplier_name && (
                          <p className="text-xs text-neutral-400">
                            {row.supplier_name}
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
                      <PodForm
                        draft={draft}
                        onChange={(patch) =>
                          setDrafts((p) => ({
                            ...p,
                            [row.pod_product_id]: {
                              ...p[row.pod_product_id],
                              ...patch,
                            },
                          }))
                        }
                        categories={categories}
                        suppliers={suppliers}
                        customCode={row.custom_code ?? ""}
                      />
                      {saveMsg[row.pod_product_id] && (
                        <p
                          className={`mt-2 text-xs font-medium ${saveMsg[row.pod_product_id].startsWith("Error") ? "text-red-600" : "text-green-600"}`}
                        >
                          {saveMsg[row.pod_product_id]}
                        </p>
                      )}
                      <div className="mt-3 flex gap-2">
                        <button
                          onClick={() => saveEdit(row.pod_product_id)}
                          disabled={saving[row.pod_product_id]}
                          className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
                        >
                          {saving[row.pod_product_id] ? "Saving…" : "Save"}
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
      )}

      {/* ── Aliases tab ── */}
      {activeTab === "aliases" && (
        <div className="px-4 py-4">
          <input
            type="text"
            value={aliasSearch}
            onChange={(e) => setAliasSearch(e.target.value)}
            placeholder="Search names…"
            className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
          />
          <p className="mb-3 text-xs text-neutral-500">
            {aliasGroups.length} canonical names
          </p>

          <ul className="space-y-2">
            {aliasGroups.map(
              ({ official_name: officialName, aliases: group }) => {
                const isOpen = expandedGroup === officialName;
                const isRenaming = renamingGroup === officialName;
                return (
                  <li
                    key={officialName}
                    className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <button
                      className="w-full p-3 text-left"
                      onClick={() => {
                        if (isRenaming) return;
                        setExpandedGroup(isOpen ? null : officialName);
                        setAddAliasForGroup(null);
                        setInlineAlias("");
                        setInlineAliasError(null);
                      }}
                    >
                      <div className="flex items-center justify-between">
                        <div className="min-w-0 flex-1">
                          <p className="text-sm font-semibold truncate">
                            {officialName}
                          </p>
                          <p className="text-xs text-neutral-500">
                            {group.length} alias{group.length !== 1 ? "es" : ""}
                          </p>
                        </div>
                        <span className="shrink-0 text-xs text-neutral-400">
                          {isOpen ? "▲" : "▼"}
                        </span>
                      </div>
                    </button>

                    {isOpen && (
                      <div className="border-t border-neutral-100 px-3 pb-3 pt-2 dark:border-neutral-800">
                        {/* Rename row */}
                        {isRenaming ? (
                          <div className="mb-2 flex gap-2">
                            <input
                              type="text"
                              value={renameValue}
                              onChange={(e) => setRenameValue(e.target.value)}
                              autoFocus
                              className="flex-1 rounded border border-neutral-300 px-2 py-1 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                            />
                            <button
                              onClick={() => handleRenameGroup(officialName)}
                              disabled={renameSaving}
                              className="rounded bg-blue-600 px-2 py-1 text-xs text-white disabled:opacity-50"
                            >
                              {renameSaving ? "…" : "Save"}
                            </button>
                            <button
                              onClick={() => {
                                setRenamingGroup(null);
                                setRenameValue("");
                              }}
                              className="rounded border border-neutral-300 px-2 py-1 text-xs text-neutral-500"
                            >
                              ✕
                            </button>
                          </div>
                        ) : (
                          <button
                            onClick={() => {
                              setRenamingGroup(officialName);
                              setRenameValue(officialName);
                            }}
                            className="mb-2 text-xs text-neutral-400 hover:text-blue-600"
                          >
                            Rename official name ({group.length} aliases will
                            update)
                          </button>
                        )}

                        {/* Alias list */}
                        <ul className="space-y-1">
                          {group.map((alias) => (
                            <li
                              key={alias.id}
                              className="flex items-center gap-2 py-1"
                            >
                              <span className="min-w-0 flex-1 truncate text-xs text-neutral-700 dark:text-neutral-300">
                                {alias.original_name}
                              </span>
                              {alias.mapped_at && (
                                <span className="shrink-0 text-xs text-neutral-400">
                                  {new Date(
                                    alias.mapped_at,
                                  ).toLocaleDateString()}
                                </span>
                              )}
                              <button
                                onClick={() => deleteAlias(alias.id)}
                                className="shrink-0 text-base leading-none text-neutral-400 hover:text-red-500"
                              >
                                ×
                              </button>
                            </li>
                          ))}
                        </ul>

                        {/* Inline add */}
                        {addAliasForGroup === officialName ? (
                          <div className="mt-2 space-y-1">
                            <div className="flex gap-2">
                              <input
                                type="text"
                                value={inlineAlias}
                                onChange={(e) => setInlineAlias(e.target.value)}
                                placeholder="Original name…"
                                autoFocus
                                className="flex-1 rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-600 dark:bg-neutral-900"
                              />
                              <button
                                onClick={() => addInlineAlias(officialName)}
                                disabled={addingAlias}
                                className="rounded bg-blue-600 px-2 py-1 text-xs text-white disabled:opacity-50"
                              >
                                Add
                              </button>
                              <button
                                onClick={() => {
                                  setAddAliasForGroup(null);
                                  setInlineAlias("");
                                  setInlineAliasError(null);
                                }}
                                className="rounded border border-neutral-300 px-2 py-1 text-xs text-neutral-500"
                              >
                                ✕
                              </button>
                            </div>
                            {inlineAliasError && (
                              <p className="text-xs text-red-500">
                                {inlineAliasError}
                              </p>
                            )}
                          </div>
                        ) : (
                          <button
                            onClick={() => {
                              setAddAliasForGroup(officialName);
                              setInlineAlias("");
                              setInlineAliasError(null);
                            }}
                            className="mt-2 text-xs text-blue-600 hover:underline"
                          >
                            + Add alias
                          </button>
                        )}
                      </div>
                    )}
                  </li>
                );
              },
            )}
          </ul>
        </div>
      )}

      {/* ── Add product bottom sheet ── */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div
            className="absolute inset-0 bg-black/50"
            onClick={() => setShowAdd(false)}
          />
          <div className="relative z-10 max-h-[90vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">
              Add Pod Product
            </h3>
            {addError && (
              <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">
                {addError}
              </div>
            )}
            <PodForm
              draft={newDraft}
              onChange={(patch) => setNewDraft((p) => ({ ...p, ...patch }))}
              categories={categories}
              suppliers={suppliers}
              customCode={generatedCode || "generating…"}
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

      {/* ── Add official name bottom sheet ── */}
      {showAddOfficial && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div
            className="absolute inset-0 bg-black/50"
            onClick={() => setShowAddOfficial(false)}
          />
          <div className="relative z-10 rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">
              New Official Name
            </h3>
            {addOfficialError && (
              <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">
                {addOfficialError}
              </div>
            )}
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">
                  Official name *
                </label>
                <input
                  type="text"
                  value={newOfficialName}
                  onChange={(e) => setNewOfficialName(e.target.value)}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                />
              </div>
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">
                  First alias (optional)
                </label>
                <input
                  type="text"
                  value={newOfficialAlias}
                  onChange={(e) => setNewOfficialAlias(e.target.value)}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                />
              </div>
            </div>
            <button
              onClick={handleAddOfficialName}
              disabled={addingOfficial}
              className="mt-4 w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {addingOfficial ? "Creating…" : "Create"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
