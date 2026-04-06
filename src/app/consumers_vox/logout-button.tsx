"use client";

import { createClient } from "@/lib/supabase/client";
import { useRouter } from "next/navigation";

export default function LogoutButton() {
  const router = useRouter();

  async function handleSignOut() {
    const supabase = createClient();
    await supabase.auth.signOut();
    router.push("/login");
  }

  return (
    <button
      onClick={handleSignOut}
      style={{
        fontSize: 12,
        color: "#8892A4",
        background: "transparent",
        border: "1px solid #1E2D42",
        borderRadius: 6,
        padding: "6px 14px",
        cursor: "pointer",
      }}
    >
      Sign out
    </button>
  );
}
