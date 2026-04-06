"use client";

import { useEffect, useState, useCallback } from "react";
import { useParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../../components/field-header";
import { ShelfGrid, type ShelfSlot } from "@/components/field/ShelfGrid";

interface MachineInfo {
  official_name: string;
  pod_location: string | null;
}

export default function ShelfViewPage() {
  const params = useParams<{ machineId: string }>();
  const machineId = params.machineId;

  const [machine, setMachine] = useState<MachineInfo | null>(null);
  const [slots, setSlots] = useState<ShelfSlot[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchData = useCallback(async () => {
    const supabase = createClient();

    const [{ data: machineData }, { data: planData }] = await Promise.all([
      supabase
        .from("machines")
        .select("official_name, pod_location")
        .eq("machine_id", machineId)
        .single(),
      supabase
        .from("v_machine_shelf_plan")
        .select(
          "shelf_id, shelf_code, row_label, door_side, pod_product_name, target_qty, current_stock, refill_qty, fill_pct, last_snapshot_at",
        )
        .eq("machine_id", machineId)
        .eq("plan_active", true)
        .limit(500),
    ]);

    if (machineData) setMachine(machineData);

    if (planData) {
      setSlots(
        planData.map((r) => ({
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
        })),
      );
    }

    setLoading(false);
  }, [machineId]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

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
          <div className="mb-3">
            <h2 className="text-lg font-semibold">{machine.official_name}</h2>
            {machine.pod_location && (
              <p className="text-sm text-neutral-500">{machine.pod_location}</p>
            )}
          </div>
        )}

        <ShelfGrid slots={slots} />
      </div>
    </div>
  );
}
