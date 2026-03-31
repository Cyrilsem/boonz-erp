"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../components/field-header";

interface Profile {
  full_name: string | null;
  role: string;
}

export default function ProfilePage() {
  const router = useRouter();
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const [signingOut, setSigningOut] = useState(false);

  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (!user) {
        setLoading(false);
        return;
      }

      const { data } = await supabase
        .from("user_profiles")
        .select("full_name, role")
        .eq("id", user.id)
        .single();

      setProfile(
        data
          ? { full_name: data.full_name, role: data.role }
          : { full_name: null, role: "field_staff" },
      );
      setLoading(false);
    }
    load();
  }, []);

  async function handleSignOut() {
    setSigningOut(true);
    const supabase = createClient();
    await supabase.auth.signOut();
    router.push("/login");
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Profile" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    );
  }

  return (
    <div>
      <FieldHeader title="Profile" />
      <div className="p-4 space-y-4">
        <div>
          <p className="text-lg font-semibold">
            {profile?.full_name ?? "User"}
          </p>
          <p className="text-sm text-neutral-500 capitalize">
            {profile?.role?.replace("_", " ") ?? "Field Staff"}
          </p>
        </div>
        <button
          onClick={handleSignOut}
          disabled={signingOut}
          className="w-full rounded-lg border border-red-300 py-2.5 text-sm font-medium text-red-600 transition-colors hover:bg-red-50 disabled:opacity-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950"
        >
          {signingOut ? "Signing out…" : "Sign out"}
        </button>
      </div>
    </div>
  );
}
