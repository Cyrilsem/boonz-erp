// PRD-087 R2 — unified Driver Requests page (replaces the separate
// Driver Adds review + Feedback Inbox locations; both old routes redirect).
import DriverRequestsHub from "@/components/dispatch/DriverRequestsHub";
import { PageHeader } from "@/components/ui/primitives";

export const dynamic = "force-dynamic";

export default function DriverRequestsPage() {
  return (
    <div className="p-8 max-w-7xl">
      <PageHeader
        title="Driver Requests"
        subtitle="Everything raised from the field — plan additions and shelf feedback, grouped by machine"
      />
      <DriverRequestsHub />
    </div>
  );
}
