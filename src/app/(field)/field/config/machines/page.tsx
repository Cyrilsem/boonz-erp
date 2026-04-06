"use client";

export const dynamic = "force-dynamic";

import { useEffect, useState, useCallback, useMemo } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../../components/field-header";
import { ShelfGrid, type ShelfSlot } from "@/components/field/ShelfGrid";

const ADMIN_ROLES = ["operator_admin", "superadmin", "manager", "warehouse"];

const DEFAULT_STATUS_OPTIONS = [
  "Active",
  "Inactive",
  "Maintenance",
  "Pending",
  "Valid",
  "Online today",
  "Switched off",
  "Scheduled",
];

// ─── Machine types ─────────────────────────────────────────────────────────────

interface Machine {
  machine_id: string;
  official_name: string;
  pod_number: string | null;
  pod_location: string | null;
  pod_address: string | null;
  status: string | null;
  contact_person: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  notes: string | null;
}

interface MachineDraft {
  official_name: string;
  pod_number: string;
  pod_location: string;
  pod_address: string;
  status: string;
  contact_person: string;
  contact_email: string;
  contact_phone: string;
  notes: string;
}

function emptyMachineDraft(): MachineDraft {
  return {
    official_name: "",
    pod_number: "",
    pod_location: "",
    pod_address: "",
    status: "Active",
    contact_person: "",
    contact_email: "",
    contact_phone: "",
    notes: "",
  };
}

function machineRowToDraft(r: Machine): MachineDraft {
  return {
    official_name: r.official_name,
    pod_number: r.pod_number ?? "",
    pod_location: r.pod_location ?? "",
    pod_address: r.pod_address ?? "",
    status: r.status ?? "Active",
    contact_person: r.contact_person ?? "",
    contact_email: r.contact_email ?? "",
    contact_phone: r.contact_phone ?? "",
    notes: r.notes ?? "",
  };
}

function MachineFormFields({
  draft,
  onChange,
  statusOptions,
}: {
  draft: MachineDraft;
  onChange: (patch: Partial<MachineDraft>) => void;
  statusOptions: string[];
}) {
  return (
    <div className="space-y-2">
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">
          Official Name *
        </label>
        <input
          type="text"
          value={draft.official_name}
          onChange={(e) => onChange({ official_name: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
        />
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Pod Number
          </label>
          <input
            type="text"
            value={draft.pod_number}
            onChange={(e) => onChange({ pod_number: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Status
          </label>
          <select
            value={draft.status}
            onChange={(e) => onChange({ status: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          >
            {statusOptions.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </div>
      </div>
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">
          Location
        </label>
        <input
          type="text"
          value={draft.pod_location}
          onChange={(e) => onChange({ pod_location: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
        />
      </div>
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">
          Address
        </label>
        <input
          type="text"
          value={draft.pod_address}
          onChange={(e) => onChange({ pod_address: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
        />
      </div>
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">
          Contact Person
        </label>
        <input
          type="text"
          value={draft.contact_person}
          onChange={(e) => onChange({ contact_person: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
        />
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Email
          </label>
          <input
            type="email"
            value={draft.contact_email}
            onChange={(e) => onChange({ contact_email: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">
            Phone
          </label>
          <input
            type="tel"
            value={draft.contact_phone}
            onChange={(e) => onChange({ contact_phone: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>
      </div>
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">
          Notes
        </label>
        <textarea
          rows={2}
          value={draft.notes}
          onChange={(e) => onChange({ notes: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
        />
      </div>
    </div>
  );
}

// ─── Alias types ──────────────────────────────────────────────────────────────

interface Alias {
  alias_id: string;
  machine_id: string;
  original_name: string;
  official_name: string;
  is_active: boolean | null;
}

// ─── CSV ──────────────────────────────────────────────────────────────────────

const CSV_COLUMNS = [
  "official_name",
  "pod_number",
  "pod_location",
  "pod_address",
  "status",
  "contact_person",
  "contact_email",
  "contact_phone",
  "notes",
];

function parseCsv(text: string): Record<string, string>[] {
  const lines = text.split("\n").filter((l) => l.trim());
  if (lines.length < 2) return [];
  const headers = lines[0]
    .split(",")
    .map((h) => h.trim().replace(/^"|"$/g, ""));
  return lines
    .slice(1)
    .map((line) => {
      const vals = line.split(",").map((v) => v.trim().replace(/^"|"$/g, ""));
      const obj: Record<string, string> = {};
      headers.forEach((h, i) => {
        obj[h] = vals[i] ?? "";
      });
      return obj;
    })
    .filter((r) => r["official_name"]);
}

// ─── Page ─────────────────────────────────────────────────────────────────────

type TabId = "machines" | "aliases" | "layout";

export default function MachinesPage() {
  const router = useRouter();
  const [activeTab, setActiveTab] = useState<TabId>("machines");

  // Restore tab from URL on mount (avoids useSearchParams Suspense requirement)
  useEffect(() => {
    const tab = new URLSearchParams(window.location.search).get(
      "tab",
    ) as TabId | null;
    if (tab === "aliases" || tab === "layout") setActiveTab(tab);
  }, []);

  // Machines tab
  const [machines, setMachines] = useState<Machine[]>([]);
  const [machineSearch, setMachineSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [machineExpanded, setMachineExpanded] = useState<string | null>(null);
  const [machineDrafts, setMachineDrafts] = useState<
    Record<string, MachineDraft>
  >({});
  const [machineSaving, setMachineSaving] = useState<Record<string, boolean>>(
    {},
  );
  const [machineSaveMsg, setMachineSaveMsg] = useState<Record<string, string>>(
    {},
  );

  // Add machine
  const [showAddMachine, setShowAddMachine] = useState(false);
  const [newMachine, setNewMachine] =
    useState<MachineDraft>(emptyMachineDraft());
  const [addingMachine, setAddingMachine] = useState(false);
  const [addMachineError, setAddMachineError] = useState<string | null>(null);

  // Bulk CSV
  const [showBulkCsv, setShowBulkCsv] = useState(false);
  const [csvPreview, setCsvPreview] = useState<Record<string, string>[]>([]);
  const [importingCsv, setImportingCsv] = useState(false);
  const [csvError, setCsvError] = useState<string | null>(null);
  const [csvResult, setCsvResult] = useState<string | null>(null);

  // Aliases tab
  const [aliases, setAliases] = useState<Alias[]>([]);
  const [aliasSearch, setAliasSearch] = useState("");
  const [aliasGroupExpanded, setAliasGroupExpanded] = useState<string | null>(
    null,
  );
  const [addAliasForGroup, setAddAliasForGroup] = useState<string | null>(null);
  const [inlineAlias, setInlineAlias] = useState("");
  const [addingAlias, setAddingAlias] = useState(false);

  const [loading, setLoading] = useState(true);

  // Layout tab
  const [layoutMachineId, setLayoutMachineId] = useState<string>("");
  const [layoutSlots, setLayoutSlots] = useState<ShelfSlot[]>([]);
  const [layoutLoading, setLayoutLoading] = useState(false);

  const fetchLayoutSlots = useCallback(async (machId: string) => {
    if (!machId) return;
    setLayoutLoading(true);
    const supabase = createClient();
    const { data } = await supabase
      .from("v_machine_shelf_plan")
      .select(
        "shelf_id, shelf_code, row_label, door_side, pod_product_name, target_qty, current_stock, refill_qty, fill_pct, last_snapshot_at, cabinet_count",
      )
      .eq("machine_id", machId)
      .eq("plan_active", true)
      .limit(500);
    if (data) {
      setLayoutSlots(
        data.map((r) => ({
          shelf_id: r.shelf_id,
          shelf_code: r.shelf_code,
          row_label: r.row_label,
          door_side: r.door_side,
          pod_product_name: r.pod_product_name,
          target_qty: r.target_qty ?? 0,
          current_stock: Number(r.current_stock ?? 0),
          refill_qty: r.refill_qty ?? 0,
          fill_pct: Number(r.fill_pct ?? 0),
          last_snapshot_at: r.last_snapshot_at ?? null,
          cabinet_count: r.cabinet_count ?? 1,
        })),
      );
    }
    setLayoutLoading(false);
  }, []);

  // When Layout tab opens, auto-select first machine if none selected
  useEffect(() => {
    if (activeTab === "layout" && machines.length > 0 && !layoutMachineId) {
      const firstId = machines[0].machine_id;
      setLayoutMachineId(firstId);
      fetchLayoutSlots(firstId);
    }
  }, [activeTab, machines, layoutMachineId, fetchLayoutSlots]);

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

    const [{ data: machineData }, { data: aliasData }] = await Promise.all([
      supabase
        .from("machines")
        .select(
          "machine_id, official_name, pod_number, pod_location, pod_address, status, contact_person, contact_email, contact_phone, notes",
        )
        .order("official_name"),
      supabase
        .from("machine_name_aliases")
        .select(
          "alias_id, machine_id, original_name, official_name, is_active, machines!inner(official_name)",
        )
        .order("official_name"),
    ]);

    if (machineData) setMachines(machineData as Machine[]);
    if (aliasData) {
      const seen = new Set<string>();
      const deduped: Alias[] = [];
      for (const r of aliasData) {
        const m = r.machines as unknown as { official_name: string };
        const a = { ...r, official_name: m.official_name } as Alias;
        const key = `${a.original_name}|||${a.official_name}`;
        if (!seen.has(key)) {
          seen.add(key);
          deduped.push(a);
        }
      }
      setAliases(deduped);
    }
    setLoading(false);
  }, [router]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Derived status options from data
  const statusOptions = useMemo(() => {
    const fromData = [
      ...new Set(machines.map((m) => m.status).filter(Boolean)),
    ] as string[];
    const combined = [
      ...new Set([...fromData, ...DEFAULT_STATUS_OPTIONS]),
    ].sort();
    return combined;
  }, [machines]);

  // Filtered machines
  const filteredMachines = useMemo(() => {
    let result = machines;
    if (statusFilter !== "all")
      result = result.filter((m) => m.status === statusFilter);
    if (machineSearch)
      result = result.filter((m) =>
        m.official_name.toLowerCase().includes(machineSearch.toLowerCase()),
      );
    return result;
  }, [machines, machineSearch, statusFilter]);

  // Grouped aliases
  const aliasGroups = useMemo(() => {
    const q = aliasSearch.toLowerCase();
    const src = q
      ? aliases.filter(
          (a) =>
            a.official_name.toLowerCase().includes(q) ||
            a.original_name.toLowerCase().includes(q),
        )
      : aliases;
    const groups: Record<string, Alias[]> = {};
    for (const a of src) {
      if (!groups[a.official_name]) groups[a.official_name] = [];
      groups[a.official_name].push(a);
    }
    return Object.entries(groups).sort(([a], [b]) => a.localeCompare(b));
  }, [aliases, aliasSearch]);

  // ── Machine edit ─────────────────────────────────────────────────────────────

  function openMachineEdit(row: Machine) {
    if (machineExpanded === row.machine_id) {
      setMachineExpanded(null);
      return;
    }
    setMachineExpanded(row.machine_id);
    setMachineDrafts((p) => ({
      ...p,
      [row.machine_id]: machineRowToDraft(row),
    }));
  }

  async function saveMachine(id: string) {
    const draft = machineDrafts[id];
    if (!draft) return;
    setMachineSaving((p) => ({ ...p, [id]: true }));
    const supabase = createClient();
    const { error } = await supabase
      .from("machines")
      .update({
        official_name: draft.official_name.trim(),
        pod_number: draft.pod_number.trim() || null,
        pod_location: draft.pod_location.trim() || null,
        pod_address: draft.pod_address.trim() || null,
        status: draft.status,
        contact_person: draft.contact_person.trim() || null,
        contact_email: draft.contact_email.trim() || null,
        contact_phone: draft.contact_phone.trim() || null,
        notes: draft.notes.trim() || null,
        updated_at: new Date().toISOString(),
      })
      .eq("machine_id", id);
    if (error) {
      setMachineSaveMsg((p) => ({ ...p, [id]: `Error: ${error.message}` }));
    } else {
      setMachineSaveMsg((p) => ({ ...p, [id]: "Saved ✓" }));
      await fetchData();
      setMachineExpanded(null);
      setTimeout(() => setMachineSaveMsg((p) => ({ ...p, [id]: "" })), 2000);
    }
    setMachineSaving((p) => ({ ...p, [id]: false }));
  }

  async function handleAddMachine() {
    if (!newMachine.official_name.trim()) {
      setAddMachineError("Official name is required");
      return;
    }
    setAddingMachine(true);
    setAddMachineError(null);
    const supabase = createClient();
    const { error } = await supabase.from("machines").insert({
      official_name: newMachine.official_name.trim(),
      pod_number: newMachine.pod_number.trim() || null,
      pod_location: newMachine.pod_location.trim() || null,
      pod_address: newMachine.pod_address.trim() || null,
      status: newMachine.status,
      contact_person: newMachine.contact_person.trim() || null,
      contact_email: newMachine.contact_email.trim() || null,
      contact_phone: newMachine.contact_phone.trim() || null,
      notes: newMachine.notes.trim() || null,
    });
    if (error) {
      setAddMachineError(error.message);
      setAddingMachine(false);
      return;
    }
    setShowAddMachine(false);
    setNewMachine(emptyMachineDraft());
    await fetchData();
    setAddingMachine(false);
  }

  // ── CSV import ────────────────────────────────────────────────────────────────

  function handleCsvFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setCsvError(null);
    setCsvResult(null);
    const reader = new FileReader();
    reader.onload = (ev) => {
      const text = ev.target?.result as string;
      const parsed = parseCsv(text);
      if (!parsed.length) {
        setCsvError("No valid rows found. Check column headers.");
        return;
      }
      setCsvPreview(parsed);
    };
    reader.readAsText(file);
  }

  async function handleCsvImport() {
    if (!csvPreview.length) return;
    setImportingCsv(true);
    setCsvError(null);
    setCsvResult(null);
    const existingNames = new Set(
      machines.map((m) => m.official_name.toLowerCase()),
    );
    const toInsert = csvPreview.filter(
      (r) => !existingNames.has((r["official_name"] ?? "").toLowerCase()),
    );
    const skipped = csvPreview.length - toInsert.length;
    if (toInsert.length === 0) {
      setCsvResult(`0 added, ${skipped} skipped (already exist)`);
      setImportingCsv(false);
      return;
    }
    const supabase = createClient();
    const { error } = await supabase.from("machines").insert(
      toInsert.map((r) => ({
        official_name: r["official_name"],
        pod_number: r["pod_number"] || null,
        pod_location: r["pod_location"] || null,
        pod_address: r["pod_address"] || null,
        status: r["status"] || "Active",
        contact_person: r["contact_person"] || null,
        contact_email: r["contact_email"] || null,
        contact_phone: r["contact_phone"] || null,
        notes: r["notes"] || null,
      })),
    );
    if (error) {
      setCsvError(error.message);
      setImportingCsv(false);
      return;
    }
    setCsvResult(
      `${toInsert.length} added, ${skipped} skipped (already exist)`,
    );
    setCsvPreview([]);
    await fetchData();
    setImportingCsv(false);
  }

  // ── Alias actions ─────────────────────────────────────────────────────────────

  async function toggleAlias(aliasId: string, current: boolean | null) {
    const supabase = createClient();
    await supabase
      .from("machine_name_aliases")
      .update({ is_active: !current })
      .eq("alias_id", aliasId);
    await fetchData();
  }

  async function deleteAlias(aliasId: string) {
    const supabase = createClient();
    await supabase
      .from("machine_name_aliases")
      .delete()
      .eq("alias_id", aliasId);
    await fetchData();
  }

  async function addInlineAlias(officialName: string) {
    if (!inlineAlias.trim()) return;
    const machine = machines.find((m) => m.official_name === officialName);
    if (!machine) return;
    setAddingAlias(true);
    const supabase = createClient();
    const { error } = await supabase.from("machine_name_aliases").insert({
      original_name: inlineAlias.trim(),
      official_name: officialName,
      machine_id: machine.machine_id,
      is_active: true,
    });
    if (!error) {
      setAddAliasForGroup(null);
      setInlineAlias("");
      await fetchData();
    }
    setAddingAlias(false);
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Machines & Aliases" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    );
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Machines & Aliases"
        rightAction={
          activeTab === "machines" ? (
            <div className="flex gap-2">
              <button
                onClick={() => {
                  setCsvPreview([]);
                  setCsvError(null);
                  setCsvResult(null);
                  setShowBulkCsv(true);
                }}
                className="rounded-lg border border-neutral-300 px-3 py-1.5 text-xs font-medium text-neutral-600 hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-800"
              >
                CSV
              </button>
              <button
                onClick={() => {
                  setNewMachine(emptyMachineDraft());
                  setAddMachineError(null);
                  setShowAddMachine(true);
                }}
                className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
              >
                + Add
              </button>
            </div>
          ) : undefined
        }
      />

      {/* Tabs */}
      <div className="flex border-b border-neutral-200 dark:border-neutral-800">
        {(["machines", "aliases", "layout"] as TabId[]).map((tab) => (
          <button
            key={tab}
            onClick={() => {
              setActiveTab(tab);
              router.replace(`?tab=${tab}`, { scroll: false });
            }}
            className={`flex-1 py-3 text-sm font-medium transition-colors capitalize ${
              activeTab === tab
                ? "border-b-2 border-blue-600 text-blue-600"
                : "text-neutral-500 hover:text-neutral-700"
            }`}
          >
            {tab}
          </button>
        ))}
      </div>

      {/* ── Machines tab ── */}
      {activeTab === "machines" && (
        <div className="px-4 py-4">
          <div className="mb-3 flex gap-2">
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              className="rounded-lg border border-neutral-300 px-2 py-2 text-xs dark:border-neutral-600 dark:bg-neutral-900"
            >
              <option value="all">All statuses</option>
              {statusOptions.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
            <input
              type="text"
              value={machineSearch}
              onChange={(e) => setMachineSearch(e.target.value)}
              placeholder="Search machines…"
              className="flex-1 rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
          <p className="mb-3 text-xs text-neutral-500">
            {filteredMachines.length} machines
          </p>

          <ul className="space-y-2">
            {filteredMachines.map((row) => {
              const isExpanded = machineExpanded === row.machine_id;
              const draft = machineDrafts[row.machine_id];
              return (
                <li
                  key={row.machine_id}
                  className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <div
                    className="cursor-pointer p-3"
                    onClick={() => openMachineEdit(row)}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0 flex-1">
                        <p className="text-sm font-semibold truncate">
                          {row.official_name}
                        </p>
                        {row.pod_number && (
                          <p className="text-xs text-neutral-500">
                            #{row.pod_number}
                          </p>
                        )}
                        {row.pod_location && (
                          <p className="text-xs text-neutral-500">
                            {row.pod_location}
                          </p>
                        )}
                        {row.contact_person && (
                          <p className="text-xs text-neutral-400">
                            {row.contact_person}
                          </p>
                        )}
                      </div>
                      <div className="shrink-0 text-right">
                        <span
                          className={`rounded-full px-2 py-0.5 text-xs font-medium ${
                            (row.status ?? "").toLowerCase() === "active" ||
                            row.status === "Online today"
                              ? "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300"
                              : "bg-neutral-100 text-neutral-500 dark:bg-neutral-800"
                          }`}
                        >
                          {row.status ?? "unknown"}
                        </span>
                        <p className="mt-1 text-xs text-neutral-400">
                          {isExpanded ? "▲" : "▼"}
                        </p>
                      </div>
                    </div>
                  </div>
                  {isExpanded && draft && (
                    <div className="border-t border-neutral-100 px-3 pb-4 pt-3 dark:border-neutral-800">
                      <MachineFormFields
                        draft={draft}
                        onChange={(patch) =>
                          setMachineDrafts((p) => ({
                            ...p,
                            [row.machine_id]: {
                              ...p[row.machine_id],
                              ...patch,
                            },
                          }))
                        }
                        statusOptions={statusOptions}
                      />
                      {machineSaveMsg[row.machine_id] && (
                        <p
                          className={`mt-2 text-xs font-medium ${machineSaveMsg[row.machine_id].startsWith("Error") ? "text-red-600" : "text-green-600"}`}
                        >
                          {machineSaveMsg[row.machine_id]}
                        </p>
                      )}
                      <div className="mt-3 flex gap-2">
                        <button
                          onClick={() => saveMachine(row.machine_id)}
                          disabled={machineSaving[row.machine_id]}
                          className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
                        >
                          {machineSaving[row.machine_id] ? "Saving…" : "Save"}
                        </button>
                        <button
                          onClick={() => setMachineExpanded(null)}
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
            placeholder="Search aliases…"
            className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
          />
          <p className="mb-3 text-xs text-neutral-500">
            {aliasGroups.length} machines with aliases
          </p>

          <ul className="space-y-2">
            {aliasGroups.map(([officialName, group]) => {
              const isOpen = aliasGroupExpanded === officialName;
              return (
                <li
                  key={officialName}
                  className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <button
                    className="w-full p-3 text-left"
                    onClick={() => {
                      setAliasGroupExpanded(isOpen ? null : officialName);
                      setAddAliasForGroup(null);
                      setInlineAlias("");
                    }}
                  >
                    <div className="flex items-center justify-between">
                      <div>
                        <p className="text-sm font-semibold">{officialName}</p>
                        <p className="text-xs text-neutral-500">
                          {group.length} alias{group.length !== 1 ? "es" : ""}
                        </p>
                      </div>
                      <span className="text-xs text-neutral-400">
                        {isOpen ? "▲" : "▼"}
                      </span>
                    </div>
                  </button>

                  {isOpen && (
                    <div className="border-t border-neutral-100 px-3 pb-3 pt-2 dark:border-neutral-800">
                      <ul className="space-y-1">
                        {group.map((alias) => (
                          <li
                            key={alias.alias_id}
                            className="flex items-center gap-2 py-1"
                          >
                            <span className="min-w-0 flex-1 truncate text-xs text-neutral-700 dark:text-neutral-300">
                              {alias.original_name}
                            </span>
                            <button
                              onClick={() =>
                                toggleAlias(alias.alias_id, alias.is_active)
                              }
                              className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${
                                alias.is_active
                                  ? "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300"
                                  : "bg-neutral-100 text-neutral-500 dark:bg-neutral-800"
                              }`}
                            >
                              {alias.is_active ? "On" : "Off"}
                            </button>
                            <button
                              onClick={() => deleteAlias(alias.alias_id)}
                              className="shrink-0 text-base leading-none text-neutral-400 hover:text-red-500"
                            >
                              ×
                            </button>
                          </li>
                        ))}
                      </ul>

                      {addAliasForGroup === officialName ? (
                        <div className="mt-2 flex gap-2">
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
                            }}
                            className="rounded border border-neutral-300 px-2 py-1 text-xs text-neutral-500"
                          >
                            ✕
                          </button>
                        </div>
                      ) : (
                        <button
                          onClick={() => {
                            setAddAliasForGroup(officialName);
                            setInlineAlias("");
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
            })}
          </ul>
        </div>
      )}

      {/* ── Layout tab ── */}
      {activeTab === "layout" && (
        <div className="px-4 py-4">
          <div className="mb-4">
            <label className="mb-1 block text-xs font-medium text-neutral-500">
              Machine
            </label>
            <select
              value={layoutMachineId}
              onChange={(e) => {
                setLayoutMachineId(e.target.value);
                fetchLayoutSlots(e.target.value);
              }}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            >
              {machines.map((m) => (
                <option key={m.machine_id} value={m.machine_id}>
                  {m.official_name}
                </option>
              ))}
            </select>
          </div>
          {layoutLoading ? (
            <div className="flex items-center justify-center py-8">
              <p className="text-neutral-500">Loading shelf plan…</p>
            </div>
          ) : (
            <ShelfGrid slots={layoutSlots} />
          )}
        </div>
      )}

      {/* ── Add machine bottom sheet ── */}
      {showAddMachine && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div
            className="absolute inset-0 bg-black/50"
            onClick={() => setShowAddMachine(false)}
          />
          <div className="relative z-10 max-h-[90vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">
              Add Machine
            </h3>
            {addMachineError && (
              <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">
                {addMachineError}
              </div>
            )}
            <MachineFormFields
              draft={newMachine}
              onChange={(patch) => setNewMachine((p) => ({ ...p, ...patch }))}
              statusOptions={statusOptions}
            />
            <button
              onClick={handleAddMachine}
              disabled={addingMachine}
              className="mt-4 w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {addingMachine ? "Creating…" : "Create Machine"}
            </button>
          </div>
        </div>
      )}

      {/* ── Bulk CSV bottom sheet ── */}
      {showBulkCsv && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div
            className="absolute inset-0 bg-black/50"
            onClick={() => setShowBulkCsv(false)}
          />
          <div className="relative z-10 max-h-[90vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-2 text-center text-base font-bold">
              Bulk Add Machines (CSV)
            </h3>
            <p className="mb-3 text-center text-xs text-neutral-400">
              Expected columns: {CSV_COLUMNS.join(", ")}
            </p>
            {csvError && (
              <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">
                {csvError}
              </div>
            )}
            {csvResult && (
              <div className="mb-3 rounded-lg bg-green-50 px-3 py-2 text-xs text-green-700 dark:bg-green-900/30 dark:text-green-300">
                {csvResult}
              </div>
            )}

            <label className="mb-3 flex cursor-pointer flex-col items-center rounded-lg border-2 border-dashed border-neutral-300 py-4 text-sm text-neutral-500 hover:border-blue-400 dark:border-neutral-700">
              <span>Choose CSV file</span>
              <input
                type="file"
                accept=".csv"
                className="sr-only"
                onChange={handleCsvFile}
              />
            </label>

            {csvPreview.length > 0 && (
              <>
                <p className="mb-2 text-xs text-neutral-500">
                  {csvPreview.length} rows to import
                </p>
                <div className="mb-3 max-h-40 overflow-y-auto rounded border border-neutral-200 dark:border-neutral-700">
                  <table className="w-full text-xs">
                    <thead className="bg-neutral-50 dark:bg-neutral-800">
                      <tr>
                        <th className="px-2 py-1 text-left">Official name</th>
                        <th className="px-2 py-1 text-left">Location</th>
                        <th className="px-2 py-1 text-left">Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {csvPreview.map((r, i) => (
                        <tr
                          key={i}
                          className="border-t border-neutral-100 dark:border-neutral-800"
                        >
                          <td className="px-2 py-1">{r["official_name"]}</td>
                          <td className="px-2 py-1 text-neutral-500">
                            {r["pod_location"]}
                          </td>
                          <td className="px-2 py-1 text-neutral-500">
                            {r["status"]}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <button
                  onClick={handleCsvImport}
                  disabled={importingCsv}
                  className="w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
                >
                  {importingCsv
                    ? "Importing…"
                    : `Import ${csvPreview.length} machines`}
                </button>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
