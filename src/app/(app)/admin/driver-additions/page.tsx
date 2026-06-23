import DriverAdditionsReviewPanel from "@/components/dispatch/DriverAdditionsReviewPanel";

export const dynamic = "force-dynamic";

export default function DriverAdditionsReviewPage() {
  return (
    <div className="mx-auto max-w-4xl space-y-4 p-4">
      <header>
        <h1 className="text-xl font-semibold">
          Driver additions — Head Office review
        </h1>
        <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
          Lines a driver added beyond the plan (PRD-053). Each is recorded and
          flagged, never silently changing the books. Accept or reject; the
          decision is logged via <code>review_driver_addition</code>.
        </p>
      </header>
      <DriverAdditionsReviewPanel />
    </div>
  );
}
