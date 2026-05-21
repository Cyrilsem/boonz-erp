import QuarantinedInventoryPanel from "@/components/inventory/QuarantinedInventoryPanel";

export const dynamic = "force-dynamic";

export default function WhQuarantinePage() {
  return (
    <div className="mx-auto max-w-6xl space-y-4 p-4">
      <header>
        <h1 className="text-xl font-semibold">
          Warehouse inventory — needs review
        </h1>
        <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
          Rows whose origin event is unknown or pre-dates the PRD-003 provenance
          rollout. The refill brain skips these rows until they are reconciled
          via <code>adjust_warehouse_stock</code> with an explicit provenance.
        </p>
      </header>
      <QuarantinedInventoryPanel />
    </div>
  );
}
