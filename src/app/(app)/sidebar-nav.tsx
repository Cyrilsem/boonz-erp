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
  { label: "Refill & Dispatch", href: "/refill", icon: "↻" },
  { label: "Products", href: "/app/products", icon: "☐" },
  { label: "Inventory", href: "/app/inventory", icon: "▤" },
  { label: "Procurement", href: "/app/procurement", icon: "☐" },
  { label: "Financials", href: "/app/financials", icon: "$" },
  { label: "Suppliers", href: "/app/suppliers", icon: "⇠" },
  { label: "Consumers", href: "/refill/consumers", icon: "⇢" },
  { label: "Lifecycle", href: "/app/lifecycle", icon: "⬡" },
  { label: "SIM Cards", href: "/field/config/sims", icon: "◈" },
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
      className={`flex flex-col shrink-0 transition-[width] ${
        collapsed ? "w-14" : "w-56"
      } max-md:w-14`}
      style={{
        background: "#24544a",
        borderRight: "1px solid #1d4439",
      }}
    >
      {/* Logo bar */}
      <div
        className="flex h-14 items-center justify-between px-3"
        style={{ borderBottom: "1px solid rgba(255,255,255,0.08)" }}
      >
        {!collapsed && (
          <span
            className="max-md:hidden"
            style={{
              fontFamily: "'Plus Jakarta Sans', sans-serif",
              fontWeight: 800,
              fontSize: 16,
              letterSpacing: "-0.02em",
              color: "#0a0a0a",
            }}
          >
            Boonz
          </span>
        )}
        <button
          onClick={() => setCollapsed(!collapsed)}
          className="rounded p-1 max-md:hidden transition-colors"
          style={{ color: "rgba(255,255,255,0.5)" }}
          onMouseEnter={(e) =>
            ((e.currentTarget as HTMLButtonElement).style.color = "white")
          }
          onMouseLeave={(e) =>
            ((e.currentTarget as HTMLButtonElement).style.color =
              "rgba(255,255,255,0.5)")
          }
          aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
        >
          {collapsed ? "▸" : "◂"}
        </button>
      </div>

      {/* Nav items */}
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
              className="flex items-center gap-3 px-3 py-2 mx-1 rounded text-sm transition-colors"
              style={
                active
                  ? {
                      background: "#0a0a0a",
                      color: "white",
                      fontWeight: 600,
                    }
                  : {
                      color: "rgba(255,255,255,0.7)",
                    }
              }
              onMouseEnter={(e) => {
                if (!active) {
                  (e.currentTarget as HTMLAnchorElement).style.background =
                    "rgba(255,255,255,0.10)";
                  (e.currentTarget as HTMLAnchorElement).style.color = "white";
                }
              }}
              onMouseLeave={(e) => {
                if (!active) {
                  (e.currentTarget as HTMLAnchorElement).style.background =
                    "transparent";
                  (e.currentTarget as HTMLAnchorElement).style.color =
                    "rgba(255,255,255,0.7)";
                }
              }}
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
