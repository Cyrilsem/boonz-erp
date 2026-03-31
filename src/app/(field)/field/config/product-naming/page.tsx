"use client";

export const dynamic = "force-dynamic";

import { useEffect, useState, useCallback, useMemo } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../../components/field-header";

const ADMIN_ROLES = ["operator_admin", "superadmin", "manager"];

interface ConventionRow {
  id: string;
  original_name: string;
  official_name: string;
  mapped_at: string | null;
}

interface OfficialGroup {
  official_name: string;
  alias_count: number;
}

export default function ProductNamingPage() {
  const router = useRouter();

  const [loading, setLoading] = useState(true);
  const [conventions, setConventions] = useState<ConventionRow[]>([]);
  const [search, setSearch] = useState("");

  // Accordion
  const [expandedName, setExpandedName] = useState<string | null>(null);
  const [aliases, setAliases] = useState<ConventionRow[]>([]);
  const [aliasLoading, setAliasLoading] = useState(false);

  // Add alias
  const [newAlias, setNewAlias] = useState("");
  const [addingAlias, setAddingAlias] = useState(false);
  const [addAliasError, setAddAliasError] = useState<string | null>(null);

  // Rename
  const [renaming, setRenaming] = useState(false);
  const [renameValue, setRenameValue] = useState("");
  const [renameSaving, setRenameSaving] = useState(false);
  const [renameError, setRenameError] = useState<string | null>(null);

  // Add official name modal
  const [showAdd, setShowAdd] = useState(false);
  const [addOfficialName, setAddOfficialName] = useState("");
  const [addFirstAlias, setAddFirstAlias] = useState("");
  const [addError, setAddError] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);

  const load = useCallback(async () => {
    const supabase = createClient();
    const { data } = await supabase
      .from("product_name_conventions")
      .select("id, original_name, official_name, mapped_at")
      .order("original_name");

    if (data) {
      // Deduplicate by (original_name, official_name)
      const seen = new Set<string>();
      const deduped: ConventionRow[] = [];
      for (const r of data) {
        const key = `${r.original_name}|||${r.official_name ?? ""}`;
        if (seen.has(key)) continue;
        seen.add(key);
        deduped.push({
          id: r.id,
          original_name: r.original_name ?? "",
          official_name: r.official_name ?? "",
          mapped_at: r.mapped_at ?? null,
        });
      }
      setConventions(deduped);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    async function init() {
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
      await load();
    }
    init();
  }, [router, load]);

  // Group by official_name, counting distinct original_names
  const officialGroups = useMemo<OfficialGroup[]>(() => {
    const map = new Map<string, Set<string>>();
    for (const r of conventions) {
      if (!map.has(r.official_name)) map.set(r.official_name, new Set());
      map.get(r.official_name)!.add(r.original_name);
    }
    return [...map.entries()]
      .map(([official_name, originals]) => ({
        official_name,
        alias_count: originals.size,
      }))
      .sort((a, b) => a.official_name.localeCompare(b.official_name));
  }, [conventions]);

  const filteredGroups = useMemo(() => {
    if (!search.trim()) return officialGroups;
    const q = search.toLowerCase();
    return officialGroups.filter((g) =>
      g.official_name.toLowerCase().includes(q),
    );
  }, [officialGroups, search]);

  async function loadAliases(officialName: string) {
    setAliasLoading(true);
    const supabase = createClient();
    const { data } = await supabase
      .from("product_name_conventions")
      .select("id, original_name, official_name, mapped_at")
      .eq("official_name", officialName)
      .order("original_name");

    if (data) {
      // Deduplicate by original_name (keep first occurrence)
      const seen = new Set<string>();
      const deduped: ConventionRow[] = [];
      for (const r of data) {
        if (seen.has(r.original_name ?? "")) continue;
        seen.add(r.original_name ?? "");
        deduped.push({
          id: r.id,
          original_name: r.original_name ?? "",
          official_name: r.official_name ?? "",
          mapped_at: r.mapped_at ?? null,
        });
      }
      setAliases(deduped);
    }
    setAliasLoading(false);
  }

  async function toggleAccordion(officialName: string) {
    if (expandedName === officialName) {
      setExpandedName(null);
      setAliases([]);
      setRenaming(false);
      setNewAlias("");
      setAddAliasError(null);
      return;
    }
    setExpandedName(officialName);
    setRenaming(false);
    setRenameValue(officialName);
    setRenameError(null);
    setNewAlias("");
    setAddAliasError(null);
    await loadAliases(officialName);
  }

  async function deleteAlias(id: string, officialName: string) {
    const supabase = createClient();
    await supabase.from("product_name_conventions").delete().eq("id", id);
    await Promise.all([loadAliases(officialName), load()]);
  }

  async function addAlias(officialName: string) {
    const name = newAlias.trim();
    if (!name) return;
    setAddingAlias(true);
    setAddAliasError(null);
    const supabase = createClient();

    const { data: existing } = await supabase
      .from("product_name_conventions")
      .select("id")
      .eq("original_name", name)
      .maybeSingle();
    if (existing) {
      setAddAliasError("Already exists");
      setAddingAlias(false);
      return;
    }

    const today = new Date().toISOString().slice(0, 10);
    const { error } = await supabase.from("product_name_conventions").insert({
      original_name: name,
      official_name: officialName,
      mapped_at: today,
    });
    if (error) {
      setAddAliasError(error.message);
      setAddingAlias(false);
      return;
    }
    setNewAlias("");
    setAddingAlias(false);
    await Promise.all([loadAliases(officialName), load()]);
  }

  async function renameOfficialName(oldName: string) {
    const newName = renameValue.trim();
    if (!newName || newName === oldName) {
      setRenaming(false);
      return;
    }
    const clash = officialGroups.some(
      (g) =>
        g.official_name.toLowerCase() === newName.toLowerCase() &&
        g.official_name !== oldName,
    );
    if (clash) {
      setRenameError("An official name with this value already exists");
      return;
    }
    setRenameSaving(true);
    setRenameError(null);
    const supabase = createClient();
    const { error } = await supabase
      .from("product_name_conventions")
      .update({ official_name: newName })
      .eq("official_name", oldName);
    if (error) {
      setRenameError(error.message);
      setRenameSaving(false);
      return;
    }
    setRenameSaving(false);
    setRenaming(false);
    setExpandedName(newName);
    await Promise.all([load(), loadAliases(newName)]);
  }

  async function handleAddCreate() {
    const name = addOfficialName.trim();
    if (!name) {
      setAddError("Official name is required");
      return;
    }
    const exists = officialGroups.some(
      (g) => g.official_name.toLowerCase() === name.toLowerCase(),
    );
    if (exists) {
      setAddError("Already exists");
      return;
    }
    setAdding(true);
    setAddError(null);
    const today = new Date().toISOString().slice(0, 10);
    const supabase = createClient();
    const rows: {
      original_name: string;
      official_name: string;
      mapped_at: string;
    }[] = [{ original_name: name, official_name: name, mapped_at: today }];
    if (addFirstAlias.trim()) {
      rows.push({
        original_name: addFirstAlias.trim(),
        official_name: name,
        mapped_at: today,
      });
    }
    const { error } = await supabase
      .from("product_name_conventions")
      .insert(rows);
    if (error) {
      setAddError(error.message);
      setAdding(false);
      return;
    }
    setShowAdd(false);
    setAddOfficialName("");
    setAddFirstAlias("");
    setAdding(false);
    await load();
    setExpandedName(name);
    await loadAliases(name);
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Product Naming" />
        <div className="flex items-center justify-center p-12 text-sm text-neutral-400">
          Loading…
        </div>
      </>
    );
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Product Naming"
        rightAction={
          <button
            onClick={() => {
              setShowAdd(true);
              setAddOfficialName("");
              setAddFirstAlias("");
              setAddError(null);
            }}
            className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700"
          >
            + New official name
          </button>
        }
      />

      <div className="space-y-2 px-4 py-3">
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search official name…"
          className="w-full rounded-lg border border-neutral-200 bg-white px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900"
        />
        <p className="text-xs text-neutral-400">
          {officialGroups.length} official name
          {officialGroups.length !== 1 ? "s" : ""}
        </p>
      </div>

      <ul className="space-y-2 px-4">
        {filteredGroups.length === 0 && (
          <li className="py-10 text-center text-sm text-neutral-400">
            {search ? "No matches" : "No official names yet"}
          </li>
        )}
        {filteredGroups.map((g) => {
          const isOpen = expandedName === g.official_name;
          return (
            <li
              key={g.official_name}
              className="overflow-hidden rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
            >
              <button
                className="flex w-full items-center justify-between px-4 py-3 text-left"
                onClick={() => toggleAccordion(g.official_name)}
              >
                <p className="max-w-[70%] truncate text-sm font-semibold">
                  {g.official_name}
                </p>
                <div className="flex shrink-0 items-center gap-2">
                  <span className="rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
                    {g.alias_count} alias{g.alias_count !== 1 ? "es" : ""}
                  </span>
                  <span className="text-xs text-neutral-400">
                    {isOpen ? "▲" : "▼"}
                  </span>
                </div>
              </button>

              {isOpen && (
                <div className="space-y-4 border-t border-neutral-100 px-4 pb-4 pt-3 dark:border-neutral-800">
                  <p className="text-base font-bold">{g.official_name}</p>

                  {/* Rename */}
                  {!renaming ? (
                    <button
                      onClick={() => {
                        setRenaming(true);
                        setRenameValue(g.official_name);
                        setRenameError(null);
                      }}
                      className="text-xs font-medium text-blue-600 hover:text-blue-800"
                    >
                      Rename official name
                    </button>
                  ) : (
                    <div className="space-y-2">
                      <p className="text-xs font-medium text-amber-600">
                        This will update all {aliases.length} alias
                        {aliases.length !== 1 ? "es" : ""} to use the new name.
                      </p>
                      <div className="flex gap-2">
                        <input
                          type="text"
                          value={renameValue}
                          onChange={(e) => setRenameValue(e.target.value)}
                          className="flex-1 rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                        />
                        <button
                          onClick={() => renameOfficialName(g.official_name)}
                          disabled={renameSaving}
                          className="rounded-lg bg-neutral-900 px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
                        >
                          {renameSaving ? "Saving…" : "Save"}
                        </button>
                        <button
                          onClick={() => setRenaming(false)}
                          className="text-xs text-neutral-400 hover:text-neutral-600"
                        >
                          Cancel
                        </button>
                      </div>
                      {renameError && (
                        <p className="text-xs text-red-600">{renameError}</p>
                      )}
                    </div>
                  )}

                  {/* Alias list */}
                  <div className="space-y-1">
                    {aliasLoading ? (
                      <p className="text-xs text-neutral-400">
                        Loading aliases…
                      </p>
                    ) : aliases.length === 0 ? (
                      <p className="text-xs text-neutral-400">No aliases yet</p>
                    ) : (
                      aliases.map((a) => (
                        <div
                          key={a.id}
                          className="flex items-center justify-between gap-2 rounded-lg bg-neutral-50 px-3 py-2 dark:bg-neutral-900"
                        >
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-xs font-medium">
                              {a.original_name}
                            </p>
                            {a.mapped_at && (
                              <p className="text-xs text-neutral-400">
                                {a.mapped_at.slice(0, 10)}
                              </p>
                            )}
                          </div>
                          <button
                            onClick={() => deleteAlias(a.id, g.official_name)}
                            className="shrink-0 text-sm font-bold text-red-400 hover:text-red-600"
                          >
                            ×
                          </button>
                        </div>
                      ))
                    )}
                  </div>

                  {/* Add alias */}
                  <div className="space-y-2">
                    <p className="text-xs font-medium text-neutral-500">
                      Add alias
                    </p>
                    <div className="flex gap-2">
                      <input
                        type="text"
                        value={newAlias}
                        onChange={(e) => setNewAlias(e.target.value)}
                        placeholder="New variant name…"
                        onKeyDown={(e) => {
                          if (e.key === "Enter") addAlias(g.official_name);
                        }}
                        className="flex-1 rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                      />
                      <button
                        onClick={() => addAlias(g.official_name)}
                        disabled={addingAlias || !newAlias.trim()}
                        className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
                      >
                        {addingAlias ? "…" : "Add"}
                      </button>
                    </div>
                    {addAliasError && (
                      <p className="text-xs text-red-600">{addAliasError}</p>
                    )}
                  </div>
                </div>
              )}
            </li>
          );
        })}
      </ul>

      {/* Add new official name modal */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div
            className="absolute inset-0 bg-black/50"
            onClick={() => setShowAdd(false)}
          />
          <div className="relative z-10 max-h-[85vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">
              New Official Name
            </h3>

            {addError && (
              <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">
                {addError}
              </div>
            )}

            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">
                  Official name *
                </label>
                <input
                  type="text"
                  value={addOfficialName}
                  onChange={(e) => setAddOfficialName(e.target.value)}
                  placeholder="e.g. Nescafé Original"
                  className="w-full rounded-lg border border-neutral-200 bg-white px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800"
                />
              </div>
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">
                  First alias (optional)
                </label>
                <p className="mb-1 text-xs text-neutral-400">
                  If this name appears differently in raw data, add it here.
                </p>
                <input
                  type="text"
                  value={addFirstAlias}
                  onChange={(e) => setAddFirstAlias(e.target.value)}
                  placeholder="e.g. NESCAFE ORIGINAL 200G"
                  className="w-full rounded-lg border border-neutral-200 bg-white px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800"
                />
              </div>
              <button
                onClick={handleAddCreate}
                disabled={adding}
                className="w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
              >
                {adding ? "Creating…" : "Create"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
