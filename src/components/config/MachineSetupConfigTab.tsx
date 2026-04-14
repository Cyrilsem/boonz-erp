"use client";

import { useState, useCallback, useEffect } from "react";
import { createClient } from "@/lib/supabase/client";
import { PAYMENT_FIELDS, HW_FIELDS } from "@/types/machines";

interface MachineStub {
  machine_id: string;
  official_name: string;
}

interface SetupDraft {
  // Adyen
  adyen_unique_terminal_id: string;
  adyen_permanent_terminal_id: string;
  adyen_status: string;
  adyen_inventory_in_store: string;
  adyen_store_code: string;
  adyen_store_description: string;
  adyen_fridge_assigned: string;
  // Micron / App
  micron_app_id: string;
  app_version: string;
  micron_version: string;
  // Payment checklist (10 booleans)
  payment_terminal_installed: boolean;
  payment_micron_bo_setup: boolean;
  payment_adyen_store_created: boolean;
  payment_connect_store_terminal: boolean;
  payment_general_ui_updated: boolean;
  payment_pos_hide_button: boolean;
  payment_app_deployed: boolean;
  payment_app_deployed_terminal: boolean;
  payment_kiosk_mode: boolean;
  payment_fan_test: boolean;
  // HW checklist (4 booleans)
  hw_compressor_ok: boolean;
  hw_calibration_ok: boolean;
  hw_door_spring_ok: boolean;
  hw_test_successful: boolean;
  // WiFi
  wifi_network_name: string;
  wifi_mac_address: string;
  wifi_device_hostname: string;
}

function emptyDraft(): SetupDraft {
  return {
    adyen_unique_terminal_id: "",
    adyen_permanent_terminal_id: "",
    adyen_status: "",
    adyen_inventory_in_store: "",
    adyen_store_code: "",
    adyen_store_description: "",
    adyen_fridge_assigned: "",
    micron_app_id: "",
    app_version: "",
    micron_version: "",
    payment_terminal_installed: false,
    payment_micron_bo_setup: false,
    payment_adyen_store_created: false,
    payment_connect_store_terminal: false,
    payment_general_ui_updated: false,
    payment_pos_hide_button: false,
    payment_app_deployed: false,
    payment_app_deployed_terminal: false,
    payment_kiosk_mode: false,
    payment_fan_test: false,
    hw_compressor_ok: false,
    hw_calibration_ok: false,
    hw_door_spring_ok: false,
    hw_test_successful: false,
    wifi_network_name: "",
    wifi_mac_address: "",
    wifi_device_hostname: "",
  };
}

function rowToDraft(row: Record<string, unknown>): SetupDraft {
  const str = (v: unknown) => (v == null ? "" : String(v));
  const bool = (v: unknown) => v === true;
  return {
    adyen_unique_terminal_id: str(row.adyen_unique_terminal_id),
    adyen_permanent_terminal_id: str(row.adyen_permanent_terminal_id),
    adyen_status: str(row.adyen_status),
    adyen_inventory_in_store: str(row.adyen_inventory_in_store),
    adyen_store_code: str(row.adyen_store_code),
    adyen_store_description: str(row.adyen_store_description),
    adyen_fridge_assigned: str(row.adyen_fridge_assigned),
    micron_app_id: str(row.micron_app_id),
    app_version: str(row.app_version),
    micron_version: str(row.micron_version),
    payment_terminal_installed: bool(row.payment_terminal_installed),
    payment_micron_bo_setup: bool(row.payment_micron_bo_setup),
    payment_adyen_store_created: bool(row.payment_adyen_store_created),
    payment_connect_store_terminal: bool(row.payment_connect_store_terminal),
    payment_general_ui_updated: bool(row.payment_general_ui_updated),
    payment_pos_hide_button: bool(row.payment_pos_hide_button),
    payment_app_deployed: bool(row.payment_app_deployed),
    payment_app_deployed_terminal: bool(row.payment_app_deployed_terminal),
    payment_kiosk_mode: bool(row.payment_kiosk_mode),
    payment_fan_test: bool(row.payment_fan_test),
    hw_compressor_ok: bool(row.hw_compressor_ok),
    hw_calibration_ok: bool(row.hw_calibration_ok),
    hw_door_spring_ok: bool(row.hw_door_spring_ok),
    hw_test_successful: bool(row.hw_test_successful),
    wifi_network_name: str(row.wifi_network_name),
    wifi_mac_address: str(row.wifi_mac_address),
    wifi_device_hostname: str(row.wifi_device_hostname),
  };
}

function Toggle({
  checked,
  onChange,
  label,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label: string;
}) {
  return (
    <label className="flex cursor-pointer items-center justify-between gap-2 py-1">
      <span className="text-sm text-gray-700">{label}</span>
      <div
        role="switch"
        aria-checked={checked}
        onClick={() => onChange(!checked)}
        className={`relative inline-flex h-6 w-11 shrink-0 cursor-pointer items-center rounded-full transition-colors ${
          checked ? "bg-blue-600" : "bg-gray-200"
        }`}
      >
        <span
          className={`inline-block h-4 w-4 rounded-full bg-white shadow transition-transform ${
            checked ? "translate-x-6" : "translate-x-1"
          }`}
        />
      </div>
    </label>
  );
}

function SectionHeader({ title }: { title: string }) {
  return (
    <p className="mb-2 mt-4 text-xs font-semibold uppercase tracking-wide text-gray-500 first:mt-0">
      {title}
    </p>
  );
}

function TextRow({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="mb-2">
      <label className="mb-0.5 block text-xs text-gray-500">{label}</label>
      <input
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none"
      />
    </div>
  );
}

function ProgressBar({ done, total }: { done: number; total: number }) {
  const pct = total === 0 ? 0 : Math.round((done / total) * 100);
  return (
    <div className="mb-3 flex items-center gap-2">
      <div className="h-2 flex-1 overflow-hidden rounded-full bg-gray-100">
        <div
          className="h-full rounded-full bg-blue-500 transition-all"
          style={{ width: `${pct}%` }}
        />
      </div>
      <span className="text-xs text-gray-500">
        {done}/{total}
      </span>
    </div>
  );
}

export function MachineSetupConfigTab({
  machines,
}: {
  machines: MachineStub[];
}) {
  const [search, setSearch] = useState("");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<Record<string, SetupDraft>>({});
  const [loading, setLoading] = useState<Record<string, boolean>>({});
  const [saving, setSaving] = useState<Record<string, boolean>>({});
  const [saveMsg, setSaveMsg] = useState<Record<string, string>>({});

  const filtered = machines.filter((m) =>
    m.official_name.toLowerCase().includes(search.toLowerCase()),
  );

  const loadConfig = useCallback(async (machineId: string) => {
    setLoading((prev) => ({ ...prev, [machineId]: true }));
    const supabase = createClient();
    const { data } = await supabase
      .from("machines")
      .select(
        [
          "adyen_unique_terminal_id",
          "adyen_permanent_terminal_id",
          "adyen_status",
          "adyen_inventory_in_store",
          "adyen_store_code",
          "adyen_store_description",
          "adyen_fridge_assigned",
          "micron_app_id",
          "app_version",
          "micron_version",
          "payment_terminal_installed",
          "payment_micron_bo_setup",
          "payment_adyen_store_created",
          "payment_connect_store_terminal",
          "payment_general_ui_updated",
          "payment_pos_hide_button",
          "payment_app_deployed",
          "payment_app_deployed_terminal",
          "payment_kiosk_mode",
          "payment_fan_test",
          "hw_compressor_ok",
          "hw_calibration_ok",
          "hw_door_spring_ok",
          "hw_test_successful",
          "wifi_network_name",
          "wifi_mac_address",
          "wifi_device_hostname",
        ].join(","),
      )
      .eq("machine_id", machineId)
      .single();

    setDrafts((prev) => ({
      ...prev,
      [machineId]: data
        ? rowToDraft(data as unknown as Record<string, unknown>)
        : emptyDraft(),
    }));
    setLoading((prev) => ({ ...prev, [machineId]: false }));
  }, []);

  useEffect(() => {
    if (expandedId && !drafts[expandedId]) {
      loadConfig(expandedId);
    }
  }, [expandedId, drafts, loadConfig]);

  function patchDraft(machineId: string, patch: Partial<SetupDraft>) {
    setDrafts((prev) => ({
      ...prev,
      [machineId]: { ...(prev[machineId] ?? emptyDraft()), ...patch },
    }));
  }

  async function handleSave(machineId: string) {
    const draft = drafts[machineId];
    if (!draft) return;
    setSaving((prev) => ({ ...prev, [machineId]: true }));
    const supabase = createClient();
    const { error } = await supabase
      .from("machines")
      .update({
        adyen_unique_terminal_id: draft.adyen_unique_terminal_id || null,
        adyen_permanent_terminal_id: draft.adyen_permanent_terminal_id || null,
        adyen_status: draft.adyen_status || null,
        adyen_inventory_in_store: draft.adyen_inventory_in_store || null,
        adyen_store_code: draft.adyen_store_code || null,
        adyen_store_description: draft.adyen_store_description || null,
        adyen_fridge_assigned: draft.adyen_fridge_assigned || null,
        micron_app_id: draft.micron_app_id || null,
        app_version: draft.app_version || null,
        micron_version: draft.micron_version || null,
        payment_terminal_installed: draft.payment_terminal_installed,
        payment_micron_bo_setup: draft.payment_micron_bo_setup,
        payment_adyen_store_created: draft.payment_adyen_store_created,
        payment_connect_store_terminal: draft.payment_connect_store_terminal,
        payment_general_ui_updated: draft.payment_general_ui_updated,
        payment_pos_hide_button: draft.payment_pos_hide_button,
        payment_app_deployed: draft.payment_app_deployed,
        payment_app_deployed_terminal: draft.payment_app_deployed_terminal,
        payment_kiosk_mode: draft.payment_kiosk_mode,
        payment_fan_test: draft.payment_fan_test,
        hw_compressor_ok: draft.hw_compressor_ok,
        hw_calibration_ok: draft.hw_calibration_ok,
        hw_door_spring_ok: draft.hw_door_spring_ok,
        hw_test_successful: draft.hw_test_successful,
        wifi_network_name: draft.wifi_network_name || null,
        wifi_mac_address: draft.wifi_mac_address || null,
        wifi_device_hostname: draft.wifi_device_hostname || null,
      })
      .eq("machine_id", machineId);

    setSaving((prev) => ({ ...prev, [machineId]: false }));
    setSaveMsg((prev) => ({
      ...prev,
      [machineId]: error ? `Error: ${error.message}` : "Saved ✓",
    }));
    setTimeout(
      () =>
        setSaveMsg((prev) => {
          const next = { ...prev };
          delete next[machineId];
          return next;
        }),
      3000,
    );
  }

  return (
    <div className="px-4 py-4">
      <input
        type="search"
        placeholder="Search machines…"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        className="mb-3 w-full rounded-lg border border-gray-200 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none"
      />

      <div className="space-y-2">
        {filtered.map((m) => {
          const isOpen = expandedId === m.machine_id;
          const draft = drafts[m.machine_id];
          const isLoading = loading[m.machine_id];
          const isSaving = saving[m.machine_id];
          const msg = saveMsg[m.machine_id];

          const payDone = draft
            ? PAYMENT_FIELDS.filter(
                (f) => draft[f.key as keyof SetupDraft] === true,
              ).length
            : 0;
          const hwDone = draft
            ? HW_FIELDS.filter((f) => draft[f.key as keyof SetupDraft] === true)
                .length
            : 0;

          return (
            <div
              key={m.machine_id}
              className="overflow-hidden rounded-xl border border-gray-100 bg-white shadow-sm"
            >
              <button
                className="flex w-full items-center justify-between px-4 py-3 text-left"
                onClick={() => setExpandedId(isOpen ? null : m.machine_id)}
              >
                <span className="text-sm font-medium text-gray-900">
                  {m.official_name}
                </span>
                <span className="text-gray-400">{isOpen ? "▲" : "▼"}</span>
              </button>

              {isOpen && (
                <div className="border-t border-gray-100 px-4 pb-4 pt-3">
                  {isLoading ? (
                    <p className="py-4 text-center text-sm text-gray-400">
                      Loading…
                    </p>
                  ) : draft ? (
                    <>
                      {/* Adyen */}
                      <SectionHeader title="Adyen" />
                      <TextRow
                        label="Unique Terminal ID"
                        value={draft.adyen_unique_terminal_id}
                        onChange={(v) =>
                          patchDraft(m.machine_id, {
                            adyen_unique_terminal_id: v,
                          })
                        }
                      />
                      <TextRow
                        label="Permanent Terminal ID"
                        value={draft.adyen_permanent_terminal_id}
                        onChange={(v) =>
                          patchDraft(m.machine_id, {
                            adyen_permanent_terminal_id: v,
                          })
                        }
                      />
                      <TextRow
                        label="Status"
                        value={draft.adyen_status}
                        onChange={(v) =>
                          patchDraft(m.machine_id, { adyen_status: v })
                        }
                      />
                      <TextRow
                        label="Inventory in Store"
                        value={draft.adyen_inventory_in_store}
                        onChange={(v) =>
                          patchDraft(m.machine_id, {
                            adyen_inventory_in_store: v,
                          })
                        }
                      />
                      <TextRow
                        label="Store Code"
                        value={draft.adyen_store_code}
                        onChange={(v) =>
                          patchDraft(m.machine_id, { adyen_store_code: v })
                        }
                      />
                      <TextRow
                        label="Store Description"
                        value={draft.adyen_store_description}
                        onChange={(v) =>
                          patchDraft(m.machine_id, {
                            adyen_store_description: v,
                          })
                        }
                      />
                      <TextRow
                        label="Fridge Assigned"
                        value={draft.adyen_fridge_assigned}
                        onChange={(v) =>
                          patchDraft(m.machine_id, {
                            adyen_fridge_assigned: v,
                          })
                        }
                      />

                      {/* Micron / App */}
                      <SectionHeader title="Micron / App" />
                      <TextRow
                        label="Micron App ID"
                        value={draft.micron_app_id}
                        onChange={(v) =>
                          patchDraft(m.machine_id, { micron_app_id: v })
                        }
                      />
                      <TextRow
                        label="App Version"
                        value={draft.app_version}
                        onChange={(v) =>
                          patchDraft(m.machine_id, { app_version: v })
                        }
                      />
                      <TextRow
                        label="Micron Version"
                        value={draft.micron_version}
                        onChange={(v) =>
                          patchDraft(m.machine_id, { micron_version: v })
                        }
                      />

                      {/* Payment Checklist */}
                      <SectionHeader title="Payment Checklist" />
                      <ProgressBar
                        done={payDone}
                        total={PAYMENT_FIELDS.length}
                      />
                      {PAYMENT_FIELDS.map((f) => (
                        <Toggle
                          key={f.key}
                          label={f.label}
                          checked={
                            !!(draft[f.key as keyof SetupDraft] as boolean)
                          }
                          onChange={(v) =>
                            patchDraft(m.machine_id, {
                              [f.key]: v,
                            } as Partial<SetupDraft>)
                          }
                        />
                      ))}

                      {/* Hardware Checklist */}
                      <SectionHeader title="Hardware Checklist" />
                      <ProgressBar done={hwDone} total={HW_FIELDS.length} />
                      {HW_FIELDS.map((f) => (
                        <Toggle
                          key={f.key}
                          label={f.label}
                          checked={
                            !!(draft[f.key as keyof SetupDraft] as boolean)
                          }
                          onChange={(v) =>
                            patchDraft(m.machine_id, {
                              [f.key]: v,
                            } as Partial<SetupDraft>)
                          }
                        />
                      ))}

                      {/* WiFi */}
                      <SectionHeader title="WiFi" />
                      <TextRow
                        label="Network Name"
                        value={draft.wifi_network_name}
                        onChange={(v) =>
                          patchDraft(m.machine_id, { wifi_network_name: v })
                        }
                      />
                      <TextRow
                        label="MAC Address"
                        value={draft.wifi_mac_address}
                        onChange={(v) =>
                          patchDraft(m.machine_id, { wifi_mac_address: v })
                        }
                      />
                      <TextRow
                        label="Device Hostname"
                        value={draft.wifi_device_hostname}
                        onChange={(v) =>
                          patchDraft(m.machine_id, {
                            wifi_device_hostname: v,
                          })
                        }
                      />

                      <div className="mt-4 flex items-center gap-3">
                        <button
                          onClick={() => handleSave(m.machine_id)}
                          disabled={isSaving}
                          className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
                        >
                          {isSaving ? "Saving…" : "Save Setup Config"}
                        </button>
                        {msg && (
                          <span
                            className={`text-sm ${msg.startsWith("Error") ? "text-red-500" : "text-green-600"}`}
                          >
                            {msg}
                          </span>
                        )}
                      </div>
                    </>
                  ) : null}
                </div>
              )}
            </div>
          );
        })}

        {filtered.length === 0 && (
          <p className="py-8 text-center text-sm text-gray-400">
            No machines found
          </p>
        )}
      </div>
    </div>
  );
}
