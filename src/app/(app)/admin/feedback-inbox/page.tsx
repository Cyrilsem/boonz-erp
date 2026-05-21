import DriverFeedbackInbox from "@/components/inventory/DriverFeedbackInbox";

export const dynamic = "force-dynamic";

export default function FeedbackInboxPage() {
  return (
    <div className="mx-auto max-w-6xl space-y-4 p-4">
      <header>
        <h1 className="text-xl font-semibold">Driver feedback inbox</h1>
        <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
          On-ground notes captured by drivers at the shelf. Signal weights:
          <code className="ml-1">customer_request 3×</code>,{" "}
          <code>sale_anomaly 2×</code>, <code>observation 1×</code>. The brain
          consumes the active subset via <code>v_driver_feedback_active</code>{" "}
          once PRD-009 engine integration ships.
        </p>
      </header>
      <DriverFeedbackInbox />
    </div>
  );
}
