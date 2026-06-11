import ConsumerDashboardClient from "@/app/(app)/refill/consumers/client";

// AC5: mount the Commercial tab in the VOX (MAFE) dashboard. This route is gated to
// app_metadata.role = 'vox_admin' by middleware, and the report RPCs only ever return
// venue_group='VOX' data, so p_pods is effectively pinned to Mercato+Mirdif server-side
// (a crafted non-VOX pod returns empty). hideInternalLinks keeps it partner-facing.
export default function ConsumersVoxPage() {
  return <ConsumerDashboardClient hideInternalLinks />;
}
