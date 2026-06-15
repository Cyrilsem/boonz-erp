import { createClient } from "@/lib/supabase/server";
import SidebarNav from "./sidebar-nav";
import { InventorySessionProvider } from "@/lib/inventory/session";
import { OWNER_EMAIL } from "@/lib/auth/owner";

export default async function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  let role = "operator_admin";
  if (user) {
    const { data: profile } = await supabase
      .from("user_profiles")
      .select("role")
      .eq("id", user.id)
      .single();
    role = profile?.role ?? "operator_admin";
  }

  const isOwner = (user?.email ?? "").toLowerCase() === OWNER_EMAIL;

  return (
    <>
      {/* Plus Jakarta Sans — scoped to /app shell */}
      {/* eslint-disable-next-line @next/next/no-page-custom-font */}
      <style>{`@import url('https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700;800&display=swap');`}</style>
      <div
        className="flex h-screen"
        style={{ fontFamily: "'Plus Jakarta Sans', sans-serif" }}
      >
        <SidebarNav role={role} isOwner={isOwner} />
        <main
          className="flex-1 overflow-y-auto"
          style={{ background: "#faf9f7" }}
        >
          {/* Phase G P1: provide inventory-control session context to any
              client component below this layout (operator inventory page is
              the primary WH-manager surface that consumes it). */}
          <InventorySessionProvider>{children}</InventorySessionProvider>
        </main>
      </div>
    </>
  );
}
