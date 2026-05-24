"use client";

// Phase G PRD v2 Phase 1 B.8 canary indicator.
//
// Top-right chip on inventory pages. Heartbeats every 60s while:
//   (a) the page is mounted, AND
//   (b) a session is open.
//
// Heartbeat picks an arbitrary Active warehouse_inventory row with positive
// stock and calls attempt_inventory_correction with new_warehouse_stock equal
// to the row's current stock (apply_inventory_correction is a no-op when the
// new value equals the current). This proves the canonical RPC path is alive
// end to end: RLS, role gate, session check, SECURITY DEFINER, audit trigger,
// JSON return.
//
// Green when the last heartbeat returned result='success'. Red with the
// actual error message otherwise. Yellow on first mount before the first
// heartbeat fires.
//
// Heartbeat row picker: caches a (warehouse_id, wh_inventory_id) pair on
// first heartbeat so subsequent heartbeats hit the same row. Re-picks if
// the cached row goes Inactive or zero-stock mid-session.

import { useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { attemptCorrection, correlationId } from "@/lib/inventory/attempt-rpcs";
import { useInventorySession } from "@/lib/inventory/session";

const HEARTBEAT_MS = 60_000;

type CanaryState = "warming" | "green" | "red";

interface CanaryStatus {
  state: CanaryState;
  lastResult: string | null;
  lastError: string | null;
  lastTick: number | null;
}

interface CachedRow {
  wh_inventory_id: string;
  warehouse_stock: number;
}

async function pickCanaryRow(
  supabase: ReturnType<typeof createClient>,
  warehouseId: string,
): Promise<CachedRow | null> {
  const { data, error } = await supabase
    .from("warehouse_inventory")
    .select("wh_inventory_id, warehouse_stock")
    .eq("warehouse_id", warehouseId)
    .eq("status", "Active")
    .gt("warehouse_stock", 0)
    .order("wh_inventory_id", { ascending: true })
    .limit(1)
    .single();
  if (error || !data) return null;
  return {
    wh_inventory_id: data.wh_inventory_id as string,
    warehouse_stock: Number(data.warehouse_stock),
  };
}

export function CanaryIndicator() {
  const { session } = useInventorySession();
  const [status, setStatus] = useState<CanaryStatus>({
    state: "warming",
    lastResult: null,
    lastError: null,
    lastTick: null,
  });
  const cachedRowRef = useRef<CachedRow | null>(null);

  // When session goes away (close or aborted), reset cached row + status.
  // Derive a stable key so the reset effect only fires on the open->close edge.
  const sessionKey = session?.session_id ?? null;
  useEffect(() => {
    cachedRowRef.current = null;
  }, [sessionKey]);

  useEffect(() => {
    if (!session) return;

    let cancelled = false;

    const tick = async () => {
      if (cancelled) return;
      const supabase = createClient();
      // Refresh the cached row if missing or stale.
      if (!cachedRowRef.current) {
        cachedRowRef.current = await pickCanaryRow(
          supabase,
          session.scope_warehouse_id,
        );
        if (!cachedRowRef.current) {
          if (cancelled) return;
          setStatus({
            state: "red",
            lastResult: null,
            lastError:
              "no canary row available (no Active stock-positive row in scope)",
            lastTick: Date.now(),
          });
          return;
        }
      }

      const cached = cachedRowRef.current;
      const resp = await attemptCorrection(supabase, {
        sessionId: session.session_id,
        whInventoryId: cached.wh_inventory_id,
        // No-op write: pass the current stock so apply_inventory_correction
        // re-writes the same value. The audit row still lands.
        newWarehouseStock: cached.warehouse_stock,
        reason: "heartbeat",
        correlationId: correlationId(),
      });

      if (cancelled) return;

      // If the cached row was invalidated (deleted, inactivated mid-session),
      // drop the cache and try again on next tick.
      if (
        resp.result !== "success" &&
        resp.error &&
        /not found|forbidden|reserved/i.test(resp.error)
      ) {
        cachedRowRef.current = null;
      }

      setStatus({
        state: resp.result === "success" ? "green" : "red",
        lastResult: resp.result,
        lastError: resp.error,
        lastTick: Date.now(),
      });
    };

    // Fire one immediately, then every HEARTBEAT_MS.
    tick();
    const id = window.setInterval(tick, HEARTBEAT_MS);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [session]);

  // Render an idle chip when no session.
  if (!session) {
    return (
      <span
        className="inline-flex items-center gap-1.5 rounded-full bg-neutral-100 px-2.5 py-1 text-xs font-medium text-neutral-500 dark:bg-neutral-900 dark:text-neutral-500"
        title="Canary idle: no session open"
      >
        <span className="h-2 w-2 rounded-full bg-neutral-400" />
        Canary idle
      </span>
    );
  }

  const dotClass =
    status.state === "green"
      ? "bg-green-500"
      : status.state === "red"
        ? "bg-red-500"
        : "bg-yellow-400";
  const label =
    status.state === "green"
      ? "Canary green"
      : status.state === "red"
        ? `Canary RED: ${status.lastError ?? status.lastResult ?? "unknown"}`
        : "Canary warming...";
  const tone =
    status.state === "green"
      ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
      : status.state === "red"
        ? "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
        : "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200";

  const title = status.lastTick
    ? `Last result: ${status.lastResult ?? "n/a"}`
    : "Heartbeat warming up";

  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ${tone}`}
      title={title}
    >
      <span className={`h-2 w-2 rounded-full ${dotClass}`} />
      {label}
    </span>
  );
}
