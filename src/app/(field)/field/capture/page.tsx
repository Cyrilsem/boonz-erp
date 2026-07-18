"use client";

// RC-02 (Batch 2, PRD-100): dedicated field surface for structured refill
// capture. Mounts FieldCapturePanel (previously dead code) and wires it to
// record_actual_refill. Deep-linked from the inventory disposition flow with
// ?product=&warehouse=&qty=&expiry= so a WH qty edit that is really a refill
// lands here prefilled instead of being a blind stock overwrite.

import { Suspense } from "react";
import { useSearchParams } from "next/navigation";
import { FieldHeader } from "../../components/field-header";
import {
  FieldCapturePanel,
  type CapturePrefill,
} from "@/components/field/FieldCapturePanel";

// Default export wraps the inner component in <Suspense>. Required by
// Next.js App Router when useSearchParams() is used in a client component
// — without it, the build fails the static-render bailout check.
export default function CapturePage() {
  return (
    <Suspense
      fallback={
        <>
          <FieldHeader title="Refill Capture" />
          <div className="flex items-center justify-center p-8">
            <p className="text-neutral-500">Loading…</p>
          </div>
        </>
      }
    >
      <CapturePageInner />
    </Suspense>
  );
}

function CapturePageInner() {
  const searchParams = useSearchParams();
  const prefill: CapturePrefill = {
    boonz_product_id: searchParams.get("product") ?? undefined,
    warehouse_id: searchParams.get("warehouse") ?? undefined,
    qty: searchParams.get("qty") ?? undefined,
    expiration_date: searchParams.get("expiry") ?? undefined,
  };

  return (
    <div className="pb-24">
      <FieldHeader title="Refill Capture" />
      <div className="px-4 py-4">
        <FieldCapturePanel prefill={prefill} />
      </div>
    </div>
  );
}
