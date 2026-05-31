// Shared helpers for the lifecycle inactive-product flag.
// Reads lifecycle_product_status; writes go through the canonical RPC
// set_product_lifecycle_status (Stax S1/S2 — greppable RPC call site).

import { createClient } from "@/lib/supabase/client";

/** Returns the set of pod_product_ids currently flagged inactive. */
export async function fetchInactiveProductIds(): Promise<Set<string>> {
  const supabase = createClient();
  const { data } = await supabase
    .from("lifecycle_product_status")
    .select("pod_product_id,status")
    .eq("status", "inactive")
    .limit(10000);
  return new Set((data ?? []).map((r) => r.pod_product_id as string));
}

/** Canonical writer. Marks a product active/inactive for lifecycle analysis. */
export async function setProductLifecycleStatus(
  podProductId: string,
  status: "active" | "inactive",
  reason?: string,
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("set_product_lifecycle_status", {
    p_pod_product_id: podProductId,
    p_status: status,
    p_reason: reason ?? null,
  });
  if (error) throw new Error(error.message);
}
