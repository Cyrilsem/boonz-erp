"use client";

export const dynamic = "force-dynamic";

import { useEffect, useState, useCallback } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../components/field-header";

const CONFIG_ROLES = ["operator_admin", "superadmin", "manager", "warehouse"];

interface HubCounts {
  productMappings: number;
  boonzProducts: number;
  podProducts: number;
  machinesCount: number;
  aliasesCount: number;
  suppliers: number;
}

interface NavCard {
  title: string;
  icon: string;
  desc: string;
  href: string;
  countLabel: (c: HubCounts) => string;
}

const NAV_CARDS: NavCard[] = [
  {
    title: "Product Mapping",
    icon: "🔗",
    desc: "Link VOD products to Boonz catalog with split %",
    href: "/field/config/product-mapping",
    countLabel: (c) => `${c.productMappings} active mappings`,
  },
  {
    title: "Boonz Products",
    icon: "📦",
    desc: "Master product database",
    href: "/field/config/boonz-products",
    countLabel: (c) => `${c.boonzProducts} products`,
  },
  {
    title: "Pod Products",
    icon: "🖥️",
    desc: "VOX machine product catalog",
    href: "/field/config/pod-products",
    countLabel: (c) => `${c.podProducts} products`,
  },
  {
    title: "Machines",
    icon: "🏪",
    desc: "Machine names and aliases",
    href: "/field/config/machines",
    countLabel: (c) =>
      `${c.machinesCount} machines · ${c.aliasesCount} aliases`,
  },
  {
    title: "Suppliers",
    icon: "🚚",
    desc: "Supplier database and credentials",
    href: "/field/config/suppliers",
    countLabel: (c) => `${c.suppliers} active suppliers`,
  },
];

export default function ConfigPage() {
  const router = useRouter();
  const [counts, setCounts] = useState<HubCounts | null>(null);
  const [loading, setLoading] = useState(true);

  const fetchData = useCallback(async () => {
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) {
      router.push("/login");
      return;
    }

    const { data: profile } = await supabase
      .from("user_profiles")
      .select("role")
      .eq("id", user.id)
      .single();

    if (!profile || !CONFIG_ROLES.includes(profile.role)) {
      router.push("/field");
      return;
    }

    const [
      { count: mappingCount },
      { count: boonzCount },
      { count: podCount },
      { count: machineCount },
      { count: aliasCount },
      { count: supplierCount },
    ] = await Promise.all([
      supabase
        .from("product_mapping")
        .select("mapping_id", { count: "exact", head: true })
        .eq("status", "Active"),
      supabase
        .from("boonz_products")
        .select("product_id", { count: "exact", head: true }),
      supabase
        .from("pod_products")
        .select("pod_product_id", { count: "exact", head: true }),
      supabase
        .from("machines")
        .select("machine_id", { count: "exact", head: true }),
      supabase
        .from("machine_name_aliases")
        .select("alias_id", { count: "exact", head: true }),
      supabase
        .from("suppliers")
        .select("supplier_id", { count: "exact", head: true })
        .eq("status", "Active"),
    ]);

    setCounts({
      productMappings: mappingCount ?? 0,
      boonzProducts: boonzCount ?? 0,
      podProducts: podCount ?? 0,
      machinesCount: machineCount ?? 0,
      aliasesCount: aliasCount ?? 0,
      suppliers: supplierCount ?? 0,
    });
    setLoading(false);
  }, [router]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  if (loading) {
    return (
      <>
        <FieldHeader title="Configuration" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    );
  }

  return (
    <div className="pb-24">
      <FieldHeader title="Configuration" />
      <div className="px-4 py-4">
        <p className="mb-4 text-sm text-neutral-500">
          Manage master data and naming conventions
        </p>
        <div className="grid grid-cols-1 gap-3">
          {NAV_CARDS.map((card) => (
            <Link
              key={card.href}
              href={card.href}
              className="flex items-center gap-4 rounded-2xl border border-gray-100 bg-white p-4 shadow-sm transition-colors hover:bg-gray-50"
            >
              <span className="text-3xl">{card.icon}</span>
              <div className="min-w-0 flex-1">
                <p className="text-sm font-semibold text-gray-900">
                  {card.title}
                </p>
                <p className="text-xs text-gray-500">{card.desc}</p>
                {counts && (
                  <p className="mt-0.5 text-xs font-medium text-blue-600">
                    {card.countLabel(counts)}
                  </p>
                )}
              </div>
              <span className="text-gray-400">→</span>
            </Link>
          ))}
        </div>
      </div>
    </div>
  );
}
