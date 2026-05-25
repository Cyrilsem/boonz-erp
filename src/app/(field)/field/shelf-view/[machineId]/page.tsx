"use client";

import { useEffect, useState, useCallback, useMemo, useRef } from "react";
import { useParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../../components/field-header";
import { ShelfGrid, type ShelfSlot } from "@/components/field/ShelfGrid";
import AddProductDialog from "@/components/field/AddProductDialog";

interface MachineInfo {
  official_name: string;
  pod_location: string | null;
}

// PRD-012 B.1 + B.3: gate by role. Drivers (field_staff) plus manager roles
// can submit add-product proposals.
const PROPOSE_ROLES = new Set([
  "field_staff",
  "warehouse",
  "operator_admin",
  "superadmin",
  "manager",
]);

interface PendingAdd {
  edit_id: string;
  shelf_code: string | null;
  product_name: string | null;
  quantity: number | null;
  expiration_date: string | null;
  status: string;
  created_at: string;
  reviewed_at: string | null;
  notes: string | null;
}

export default function ShelfViewPage() {
  const params = useParams<{ machineId: string }>();
  const machineId = params.machineId;
  const supabase = useMemo(() => createClient(), []);

  const [machine, setMachine] = useState<MachineInfo | null>(null);
  const [slots, setSlots] = useState<ShelfSlot[]>([]);
  const [loading, setLoading] = useState(true);
  const [userRole, setUserRole] = useState<string | null>(null);
  const [showAddDialog, setShowAddDialog] = useState(false);
  const [pendingAdds, setPendingAdds] = useState<PendingAdd[]>([]);
  const rejectionsNotifiedRef = useRef<Set<string>>(new Set());

  const canPropose = !!userRole && PROPOSE_ROLES.has(userRole);

  const fetchData = useCallback(async () => {
    const [{ data: machineData }, { data: planData }, { data: userData }] =
      await Promise.all([
        supabase
          .from("machines")
          .select("official_name, pod_location")
          .eq("machine_id", machineId)
          .single(),
        supabase
          .from("v_live_shelf_stock")
          .select(
            "aisle_code, layer_label, goods_name_raw, max_stock, current_stock, fill_pct, snapshot_at",
          )
          .eq("machine_id", machineId)
          .eq("is_enabled", true)
          .limit(10000),
        supabase.auth.getUser(),
      ]);

    if (machineData) setMachine(machineData);

    const user = userData.user;
    if (user) {
      const { data: profile } = await supabase
        .from("user_profiles")
        .select("role")
        .eq("id", user.id)
        .single();
      setUserRole(profile?.role ?? null);
    }

    if (planData) {
      const cabinetCount = planData.some(
        (r) => (r.aisle_code ?? "A").charAt(0) === "B",
      )
        ? 2
        : 1;
      setSlots(
        planData.map((r) => ({
          shelf_id: r.aisle_code ?? "",
          shelf_code: r.aisle_code ?? "",
          row_label: r.layer_label ?? "",
          door_side: (r.aisle_code ?? "A").charAt(0),
          pod_product_name: r.goods_name_raw ?? "",
          target_qty: r.max_stock ?? 0,
          current_stock: Number(r.current_stock ?? 0),
          refill_qty: Math.max(
            (r.max_stock ?? 0) - Number(r.current_stock ?? 0),
            0,
          ),
          fill_pct: Number(r.fill_pct ?? 0),
          last_snapshot_at: r.snapshot_at ?? null,
          cabinet_count: cabinetCount,
        })),
      );
    }

    setLoading(false);
  }, [supabase, machineId]);

  // PRD-012 B.3 + B.4: fetch pending and recently-reviewed add proposals for
  // this machine; on first sight of a freshly-rejected one, alert() the driver.
  const fetchPendingAdds = useCallback(async () => {
    const { data, error } = await supabase
      .from("pod_inventory_edits")
      .select(
        "edit_id, destination_shelf_id, boonz_product_id, quantity_update, requested_expiration_date, status, created_at, reviewed_at, notes, shelf_configurations:destination_shelf_id(shelf_code), boonz_products!inner(boonz_product_name)",
      )
      .eq("machine_id", machineId)
      .eq("edit_type", "add_new_product")
      .in("status", ["pending", "rejected"])
      .order("created_at", { ascending: false })
      .limit(50);
    if (error) {
      console.error("[shelf-view] fetchPendingAdds:", error);
      return;
    }
    type Row = {
      edit_id: string;
      destination_shelf_id: string | null;
      boonz_product_id: string;
      quantity_update: number | null;
      requested_expiration_date: string | null;
      status: string;
      created_at: string;
      reviewed_at: string | null;
      notes: string | null;
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
    const mapped: PendingAdd[] = ((data as unknown as Row[] | null) ?? []).map(
      (r) => ({
        edit_id: r.edit_id,
        shelf_code: pickOne(r.shelf_configurations)?.shelf_code ?? null,
        product_name: pickOne(r.boonz_products)?.boonz_product_name ?? null,
        quantity: r.quantity_update,
        expiration_date: r.requested_expiration_date,
        status: r.status,
        created_at: r.created_at,
        reviewed_at: r.reviewed_at,
        notes: r.notes,
      }),
    );
    setPendingAdds(mapped);

    // B.4: alert on freshly-seen rejections (rejected within last 7 days,
    // not yet shown this page-load).
    const sevenDaysAgoMs = Date.now() - 7 * 24 * 60 * 60 * 1000;
    for (const row of mapped) {
      if (
        row.status === "rejected" &&
        row.reviewed_at &&
        new Date(row.reviewed_at).getTime() > sevenDaysAgoMs &&
        !rejectionsNotifiedRef.current.has(row.edit_id)
      ) {
        rejectionsNotifiedRef.current.add(row.edit_id);
        const reason = row.notes?.split("[rejection]").pop()?.trim() ?? "";
        alert(
          `Your add-product proposal was rejected.\n\nProduct: ${row.product_name ?? "?"}\nShelf: ${row.shelf_code ?? "?"}\n\nReason: ${reason || "(no reason recorded)"}`,
        );
      }
    }
  }, [supabase, machineId]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  useEffect(() => {
    fetchPendingAdds();
  }, [fetchPendingAdds]);

  if (loading) {
    return (
      <>
        <FieldHeader title="Shelf View" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading shelf plan…</p>
        </div>
      </>
    );
  }

  return (
    <div className="pb-32">
      <FieldHeader title="Shelf View" />

      <div className="px-4 pt-4">
        {machine && (
          <div className="mb-3 flex items-start justify-between gap-3">
            <div>
              <h2 className="text-lg font-semibold">{machine.official_name}</h2>
              {machine.pod_location && (
                <p className="text-sm text-neutral-500">
                  {machine.pod_location}
                </p>
              )}
            </div>
            {canPropose && (
              <button
                type="button"
                onClick={() => setShowAddDialog(true)}
                className="rounded-lg bg-neutral-900 px-3 py-2 text-xs font-semibold text-white shadow-sm"
              >
                + Add Product
              </button>
            )}
          </div>
        )}

        <ShelfGrid slots={slots} />

        {/* B.3 driver pending review section */}
        {pendingAdds.length > 0 && (
          <div className="mt-6 rounded-xl border border-neutral-200 bg-neutral-50 p-3">
            <h3 className="mb-2 text-sm font-semibold text-neutral-800">
              Your add-product proposals ({pendingAdds.length})
            </h3>
            <ul className="space-y-2">
              {pendingAdds.map((p) => (
                <li
                  key={p.edit_id}
                  className="rounded-lg border border-neutral-200 bg-white p-3 text-xs"
                >
                  <div className="flex items-center justify-between">
                    <span className="font-semibold text-neutral-900">
                      {p.product_name ?? "?"} (qty {p.quantity})
                    </span>
                    <span
                      className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${
                        p.status === "pending"
                          ? "bg-amber-100 text-amber-800"
                          : "bg-red-100 text-red-800"
                      }`}
                    >
                      {p.status}
                    </span>
                  </div>
                  <div className="mt-1 text-neutral-600">
                    Shelf {p.shelf_code ?? "?"} · expires{" "}
                    {p.expiration_date ?? "?"} · submitted{" "}
                    {new Date(p.created_at).toLocaleString("en-US", {
                      month: "short",
                      day: "numeric",
                      hour: "numeric",
                      minute: "2-digit",
                    })}
                  </div>
                  {p.status === "rejected" && p.notes && (
                    <div className="mt-2 rounded border border-red-200 bg-red-50 px-2 py-1 text-[11px] text-red-800">
                      {p.notes.split("[rejection]").pop()?.trim() ||
                        "(no reason recorded)"}
                    </div>
                  )}
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>

      {showAddDialog && machine && (
        <AddProductDialog
          machineId={machineId}
          machineName={machine.official_name}
          onClose={() => setShowAddDialog(false)}
          onSubmitted={() => {
            fetchPendingAdds();
          }}
        />
      )}
    </div>
  );
}
