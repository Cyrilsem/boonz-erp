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
        .from("v_live_shelf_stock")
        .select(
          "aisle_code, layer_label, goods_name_raw, max_stock, current_stock, fill_pct, snapshot_at",
        )
        .eq("machine_id", machineId)
        .eq("is_enabled", true)
        .limit(10000),
    ]);

    if (machineData) setMachine(machineData);

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
