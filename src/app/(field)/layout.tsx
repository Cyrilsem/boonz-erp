import BottomTabs from "./bottom-tabs";
import { InventorySessionProvider } from "@/lib/inventory/session";

export default function FieldLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="flex min-h-screen flex-col pb-12">
      {/* Phase G P1: provide inventory-control session context to any
          client component below this layout (field-side inventory list and
          per-row detail page consume it). */}
      {/* PRD-087: the field app is phone-first — on desktop, cap the content
          width so lists (packing, dispatching, pickup…) read as cards instead
          of full-bleed rows stretched across ultra-wide screens. */}
      <main className="flex-1 w-full max-w-3xl mx-auto">
        <InventorySessionProvider>{children}</InventorySessionProvider>
      </main>
      <BottomTabs />
    </div>
  );
}
