"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";

interface NavItem {
  label: string;
  href: string;
  icon: string;
}

const allNavItems: NavItem[] = [
  { label: "Dashboard", href: "/app", icon: "▦" },
  { label: "Pods", href: "/app/pods", icon: "◉" },
  { label: "Refill & Dispatch", href: "/app/refill", icon: "↻" },
  { label: "Products", href: "/app/products", icon: "☐" },
  { label: "Inventory", href: "/app/inventory", icon: "▤" },
  { label: "Financials", href: "/app/financials", icon: "$" },
  { label: "Suppliers", href: "/app/suppliers", icon: "⇠" },
  { label: "Consumers", href: "/refill/consumers", icon: "⇢" },
  { label: "Lifecycle", href: "/app/lifecycle", icon: "⬡" },
  { label: "Settings", href: "/app/settings", icon: "⚙" },
];

const hiddenByRole: Record<string, string[]> = {
  finance: ["Pods", "Refill & Dispatch", "Consumers", "Lifecycle"],
  manager: ["Settings", "Lifecycle"],
};

export default function SidebarNav({ role }: { role: string }) {
  const pathname = usePathname();
  const [collapsed, setCollapsed] = useState(false);

  const hidden = hiddenByRole[role] ?? [];
  const items = allNavItems.filter((item) => !hidden.includes(item.label));

  return (
    <aside
      className={`flex flex-col border-r border-neutral-200 bg-neutral-50 transition-[width] dark:border-neutral-800 dark:bg-neutral-950 ${
        collapsed ? "w-14" : "w-56"
      } max-md:w-14 shrink-0`}
    >
      <div className="flex h-14 items-center justify-between px-3 border-b border-neutral-200 dark:border-neutral-800">
        {!collapsed && (
          <span className="text-sm font-bold max-md:hidden">Boonz</span>
        )}
        <button
          onClick={() => setCollapsed(!collapsed)}
          className="rounded p-1 text-neutral-500 hover:bg-neutral-200 dark:hover:bg-neutral-800 max-md:hidden"
          aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
        >
          {collapsed ? "▸" : "◂"}
        </button>
      </div>

      <nav className="flex-1 overflow-y-auto py-2">
        {items.map((item) => {
          const active =
            item.href === "/app"
              ? pathname === "/app"
              : pathname.startsWith(item.href);

          return (
            <Link
              key={item.href}
              href={item.href}
              className={`flex items-center gap-3 px-3 py-2 mx-1 rounded text-sm transition-colors ${
                active
                  ? "bg-neutral-200 font-medium dark:bg-neutral-800"
                  : "text-neutral-600 hover:bg-neutral-100 dark:text-neutral-400 dark:hover:bg-neutral-900"
              }`}
            >
              <span className="w-5 text-center shrink-0">{item.icon}</span>
              <span
                className={collapsed ? "hidden max-md:hidden" : "max-md:hidden"}
              >
                {item.label}
              </span>
            </Link>
          );
        })}
      </nav>
    </aside>
  );
}
