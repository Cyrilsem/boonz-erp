"use client";

import { useEffect, useState, useCallback, useRef } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import {
  type Language,
  translations,
} from "../components/onboarding/translations";
import LanguagePicker from "../components/onboarding/language-picker";
import Tour from "../components/onboarding/tour";
import { RefillPlanReview } from "@/components/RefillPlanReview";

type Role =
  | "warehouse"
  | "field_staff"
  | "operator_admin"
  | "superadmin"
  | "manager";

const ADMIN_ROLES: Role[] = ["operator_admin", "superadmin", "manager"];

interface UserInfo {
  full_name: string | null;
  role: Role;
}

interface WarehouseKpis {
  machinesToday: number;
  packedMachines: number;
  pickedUpMachines: number;
  dispatchedMachines: number;
  expired: number;
  expiring3: number;
  expiring7: number;
  expiring30: number;
  openPOs: number;
  receivedToday: number;
  activeItems: number;
  expiringWeek: number;
  lastControlDays: number | null; // null = never
  openTasksCount: number;
  pendingPodReviews: number;
}

interface DriverKpis {
  stopsToday: number;
  pickedUpMachines: number;
  dispatchedMachines: number;
  openTasks: number;
}

interface ConfigCounts {
  boonzProducts: number;
  podProducts: number;
  suppliers: number;
  productMappings: number;
  machinesCount: number;
}

interface PodExpiryKpis {
  expired: number;
  expiring3: number;
  expiring7: number;
  expiring30: number;
}

// Per-machine stats used by both warehouse and driver branches
interface MachineStats {
  total: number;
  packed: number;
  pickedUp: number;
  dispatched: number;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function getGreeting(): string {
  const h = new Date().getHours();
  if (h < 12) return "Good morning";
  if (h < 17) return "Good afternoon";
  return "Good evening";
}

function formatToday(): string {
  return new Date().toLocaleDateString("en-US", {
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  });
}

function todayISO(): string {
  return getDubaiDate();
}

function addDays(dateStr: string, days: number): string {
  const d = new Date(dateStr + "T00:00:00");
  d.setDate(d.getDate() + days);
  return d.toISOString().split("T")[0];
}

// ─── KPI card styles ──────────────────────────────────────────────────────────

interface KpiCardStyle {
  bg: string;
  border: string;
  text: string;
  sub: string;
}

function kpiCardStyle(
  count: number,
  urgency: "critical" | "high" | "medium" | "low",
): KpiCardStyle {
  if (count === 0)
    return {
      bg: "bg-green-50",
      border: "border-green-200",
      text: "text-green-700",
      sub: "text-green-500",
    };
  const map: Record<typeof urgency, KpiCardStyle> = {
    critical: {
      bg: "bg-red-50",
      border: "border-red-200",
      text: "text-red-700",
      sub: "text-red-500",
    },
    high: {
      bg: "bg-red-50",
      border: "border-red-200",
      text: "text-red-600",
      sub: "text-red-400",
    },
    medium: {
      bg: "bg-yellow-50",
      border: "border-yellow-200",
      text: "text-yellow-700",
      sub: "text-yellow-500",
    },
    low: {
      bg: "bg-lime-50",
      border: "border-lime-200",
      text: "text-lime-700",
      sub: "text-lime-500",
    },
  };
  return map[urgency];
}

// Ratio-based card colour: gray=no data, green=all done, yellow=partial, red=not started
function ratioCardStyle(count: number, total: number): KpiCardStyle {
  if (total === 0)
    return {
      bg: "bg-gray-50",
      border: "border-gray-200",
      text: "text-gray-500",
      sub: "text-gray-400",
    };
  if (count === total)
    return {
      bg: "bg-green-50",
      border: "border-green-200",
      text: "text-green-700",
      sub: "text-green-500",
    };
  if (count > 0)
    return {
      bg: "bg-yellow-50",
      border: "border-yellow-200",
      text: "text-yellow-700",
      sub: "text-yellow-500",
    };
  return {
    bg: "bg-red-50",
    border: "border-red-200",
    text: "text-red-600",
    sub: "text-red-400",
  };
}

// ─── Section card ─────────────────────────────────────────────────────────────

function SectionCard({
  title,
  linkTo,
  rightContent,
  children,
  tourId,
}: {
  title: string;
  linkTo?: string;
  rightContent?: React.ReactNode;
  children: React.ReactNode;
  tourId?: string;
}) {
  return (
    <section
      data-tour={tourId}
      className="mb-4 rounded-2xl border border-gray-100 bg-white p-4 shadow-sm"
    >
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-sm font-bold uppercase tracking-wide text-gray-500">
          {title}
        </h2>
        <div className="flex items-center gap-2">
          {rightContent}
          {linkTo && (
            <Link href={linkTo} className="text-xs font-medium text-blue-500">
              View →
            </Link>
          )}
        </div>
      </div>
      {children}
    </section>
  );
}

// ─── Stat card ────────────────────────────────────────────────────────────────

function StatCard({
  value,
  label,
  subLabel,
  cardStyle,
  href,
}: {
  value: string | number;
  label: string;
  subLabel?: string;
  cardStyle: KpiCardStyle;
  href: string;
}) {
  return (
    <Link
      href={href}
      className={`block rounded-xl border p-3 transition-opacity hover:opacity-80 ${cardStyle.bg} ${cardStyle.border}`}
    >
      <p className={`text-2xl font-bold ${cardStyle.text}`}>{value}</p>
      <p className={`mt-0.5 text-xs font-medium ${cardStyle.text}`}>{label}</p>
      {subLabel && (
        <p className={`mt-0.5 text-xs ${cardStyle.sub}`}>{subLabel}</p>
      )}
    </Link>
  );
}

// ─── Skeleton ─────────────────────────────────────────────────────────────────

function Skeleton() {
  return (
    <div className="px-4 py-4 pb-24 space-y-4 animate-pulse">
      <div className="h-7 w-48 rounded bg-neutral-200 dark:bg-neutral-800" />
      <div className="h-4 w-36 rounded bg-neutral-200 dark:bg-neutral-800" />
      {[1, 2, 3].map((i) => (
        <div
          key={i}
          className="h-40 rounded-2xl bg-neutral-200 dark:bg-neutral-800"
        />
      ))}
    </div>
  );
}

// ─── Warehouse Home ───────────────────────────────────────────────────────────

function WarehouseHome({
  user,
  kpis,
  podKpis,
  onRestartTour,
  configCounts,
}: {
  user: UserInfo;
  kpis: WarehouseKpis;
  podKpis: PodExpiryKpis;
  onRestartTour: () => void;
  configCounts?: ConfigCounts;
}) {
  const n = kpis.machinesToday;

  const lastControlLabel =
    kpis.lastControlDays === null
      ? "Last control: Never"
      : kpis.lastControlDays === 0
        ? "Last control: Today"
        : `Last control: ${kpis.lastControlDays}d ago`;

  const lastControlColor =
    kpis.lastControlDays === null || kpis.lastControlDays > 30
      ? "text-red-500"
      : kpis.lastControlDays > 7
        ? "text-yellow-500"
        : "text-green-500";

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="text-xl font-semibold">
        {getGreeting()}, {user.full_name ?? "Warehouse"}
      </h1>
      <p className="mb-4 text-sm text-neutral-500">{formatToday()}</p>

      {/* ── Section 1: Daily Refills ── */}
      <SectionCard
        title="Daily Refills"
        linkTo="/field/packing"
        tourId="daily-refills"
      >
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={n}
            label="To refill today"
            cardStyle={ratioCardStyle(n, n)}
            href="/field/packing"
          />
          <StatCard
            value={`${kpis.packedMachines}/${n}`}
            label="Machines packed"
            cardStyle={ratioCardStyle(kpis.packedMachines, n)}
            href="/field/packing"
          />
          <StatCard
            value={`${kpis.pickedUpMachines}/${n}`}
            label="Machines picked up"
            cardStyle={ratioCardStyle(kpis.pickedUpMachines, n)}
            href="/field/pickup"
          />
          <StatCard
            value={`${kpis.dispatchedMachines}/${n}`}
            label="Machines dispatched"
            cardStyle={ratioCardStyle(kpis.dispatchedMachines, n)}
            href="/field/dispatching"
          />
        </div>
      </SectionCard>

      {/* ── Section 2: Procurement ── */}
      <SectionCard
        title="Procurement"
        linkTo="/field/orders"
        tourId="procurement"
      >
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.openPOs}
            label="Open orders"
            subLabel="Pending delivery"
            cardStyle={kpiCardStyle(kpis.openPOs, "medium")}
            href="/field/orders"
          />
          <StatCard
            value={kpis.receivedToday}
            label="Received today"
            cardStyle={kpiCardStyle(0, "low")}
            href="/field/receiving"
          />
          <Link
            href="/field/orders/new"
            className="col-span-2 flex items-center justify-center gap-2 rounded-xl border-2 border-dashed border-blue-200 bg-blue-50 py-3 text-sm font-medium text-blue-600 transition-colors hover:bg-blue-100"
          >
            + New Purchase Order
          </Link>
        </div>
      </SectionCard>

      {/* ── Section 3: Inventory ── */}
      <SectionCard
        title="Inventory"
        linkTo="/field/inventory"
        tourId="inventory"
        rightContent={
          <span className={`text-xs font-medium ${lastControlColor}`}>
            {lastControlLabel}
          </span>
        }
      >
        <p className="mb-2 mt-1 text-xs text-gray-400">Warehouse stock</p>
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.expired}
            label="Expired"
            cardStyle={kpiCardStyle(kpis.expired, "critical")}
            href="/field/inventory"
          />
          <StatCard
            value={kpis.expiring3}
            label="< 3 days"
            cardStyle={kpiCardStyle(kpis.expiring3, "high")}
            href="/field/inventory"
          />
          <StatCard
            value={kpis.expiring7}
            label="< 7 days"
            cardStyle={kpiCardStyle(kpis.expiring7, "medium")}
            href="/field/inventory"
          />
          <StatCard
            value={kpis.expiring30}
            label="< 30 days"
            cardStyle={kpiCardStyle(kpis.expiring30, "low")}
            href="/field/inventory"
          />
        </div>

        <p className="mb-2 mt-4 text-xs text-gray-400">Machine stock</p>
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={podKpis.expired}
            label="Expired"
            cardStyle={kpiCardStyle(podKpis.expired, "critical")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring3}
            label="< 3 days"
            cardStyle={kpiCardStyle(podKpis.expiring3, "high")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring7}
            label="< 7 days"
            cardStyle={kpiCardStyle(podKpis.expiring7, "medium")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring30}
            label="< 30 days"
            cardStyle={kpiCardStyle(podKpis.expiring30, "low")}
            href="/field/pod-inventory"
          />
        </div>

        {kpis.pendingPodReviews > 0 && (
          <>
            <p className="mb-2 mt-4 text-xs text-gray-400">Pod edit reviews</p>
            <div className="grid grid-cols-1 gap-3">
              <StatCard
                value={kpis.pendingPodReviews}
                label="Pod reviews pending"
                cardStyle={kpiCardStyle(kpis.pendingPodReviews, "high")}
                href="/field/inventory"
              />
            </div>
          </>
        )}
      </SectionCard>

      {/* ── Section 4: Configuration (admin roles only) ── */}
      {configCounts && (
        <SectionCard
          title="Configuration"
          linkTo="/field/config"
          tourId="config"
        >
          <div className="grid grid-cols-2 gap-3">
            <StatCard
              value={configCounts.boonzProducts}
              label="Boonz products"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/boonz-products"
            />
            <StatCard
              value={configCounts.podProducts}
              label="Pod products"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/pod-products"
            />
            <StatCard
              value={configCounts.suppliers}
              label="Active suppliers"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/suppliers"
            />
            <StatCard
              value={configCounts.productMappings}
              label="Active mappings"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/product-mapping"
            />
            <StatCard
              value={configCounts.machinesCount}
              label="Machines"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/machines"
            />
          </div>
        </SectionCard>
      )}

      {/* Restart tour */}
      <div className="mt-2 pb-4 text-center">
        <button
          onClick={onRestartTour}
          className="text-xs text-neutral-400 underline underline-offset-2 hover:text-neutral-600 dark:hover:text-neutral-300"
        >
          Restart app tour
        </button>
      </div>
    </div>
  );
}

// ─── Driver Home ──────────────────────────────────────────────────────────────

function DriverHome({
  user,
  kpis,
  podKpis,
  onRestartTour,
}: {
  user: UserInfo;
  kpis: DriverKpis;
  podKpis: PodExpiryKpis;
  onRestartTour: () => void;
}) {
  const router = useRouter();

  async function handleSignOut() {
    const supabase = createClient();
    await supabase.auth.signOut();
    router.push("/login");
  }

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="text-xl font-semibold">
        {getGreeting()}, {user.full_name ?? "Driver"}
      </h1>
      <p className="mb-4 text-sm text-neutral-500">{formatToday()}</p>

      {/* ── Section 1: Today's Route ── */}
      <SectionCard
        title="Today's Route"
        linkTo="/field/trips"
        tourId="todays-route"
      >
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.stopsToday}
            label="Stops today"
            cardStyle={ratioCardStyle(kpis.stopsToday, kpis.stopsToday)}
            href="/field/trips"
          />
          <StatCard
            value={`${kpis.pickedUpMachines}/${kpis.stopsToday}`}
            label="Machines picked up"
            cardStyle={ratioCardStyle(kpis.pickedUpMachines, kpis.stopsToday)}
            href="/field/pickup"
          />
          <StatCard
            value={`${kpis.dispatchedMachines}/${kpis.stopsToday}`}
            label="Machines dispatched"
            cardStyle={ratioCardStyle(kpis.dispatchedMachines, kpis.stopsToday)}
            href="/field/dispatching"
          />
          {/* empty cell — 3 stats only */}
          <div />
        </div>
      </SectionCard>

      {/* ── Section 2: Tasks ── */}
      <SectionCard title="Tasks" linkTo="/field/tasks" tourId="tasks">
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.openTasks}
            label="Open tasks"
            subLabel="Pending & acknowledged"
            cardStyle={kpiCardStyle(kpis.openTasks, "high")}
            href="/field/tasks"
          />
        </div>
      </SectionCard>

      {/* ── Section 3: Machine Stock Expiry ── */}
      <SectionCard
        title="Machine Stock Expiry"
        linkTo="/field/pod-inventory"
        tourId="machine-expiry"
      >
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={podKpis.expired}
            label="Expired"
            cardStyle={kpiCardStyle(podKpis.expired, "critical")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring3}
            label="< 3 days"
            cardStyle={kpiCardStyle(podKpis.expiring3, "high")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring7}
            label="< 7 days"
            cardStyle={kpiCardStyle(podKpis.expiring7, "medium")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring30}
            label="< 30 days"
            cardStyle={kpiCardStyle(podKpis.expiring30, "low")}
            href="/field/pod-inventory"
          />
        </div>
      </SectionCard>

      {/* ── Section 4: Profile ── */}
      <SectionCard title="Profile" linkTo="/field/profile" tourId="profile">
        <div className="flex items-center justify-between rounded-xl bg-gray-50 px-4 py-3">
          <div>
            <p className="text-sm font-semibold text-gray-800">
              {user.full_name ?? "Driver"}
            </p>
            <span className="mt-0.5 inline-block rounded bg-neutral-200 px-1.5 py-0.5 text-xs text-neutral-600 dark:bg-neutral-700 dark:text-neutral-300">
              Field Staff
            </span>
          </div>
          <button
            onClick={handleSignOut}
            className="rounded-lg bg-neutral-200 px-3 py-1.5 text-xs font-medium text-neutral-700 hover:bg-neutral-300 dark:bg-neutral-700 dark:text-neutral-200 dark:hover:bg-neutral-600"
          >
            Sign out
          </button>
        </div>
        <div className="mt-3 text-center">
          <button
            onClick={onRestartTour}
            className="text-xs text-neutral-400 underline underline-offset-2 hover:text-neutral-600 dark:hover:text-neutral-300"
          >
            Restart app tour
          </button>
        </div>
      </SectionCard>
    </div>
  );
}

// ─── Operator Admin Home ──────────────────────────────────────────────────────

function OperatorAdminHome({
  user,
  kpis,
  podKpis,
  onRestartTour,
  configCounts,
}: {
  user: UserInfo;
  kpis: WarehouseKpis;
  podKpis: PodExpiryKpis;
  onRestartTour: () => void;
  configCounts: ConfigCounts | null;
}) {
  const n = kpis.machinesToday;
  const pickupReadyMachines = Math.max(
    0,
    kpis.packedMachines - kpis.pickedUpMachines,
  );
  const toDispatchMachines = Math.max(
    0,
    kpis.pickedUpMachines - kpis.dispatchedMachines,
  );

  const lastControlLabel =
    kpis.lastControlDays === null
      ? "Last control: Never"
      : kpis.lastControlDays === 0
        ? "Last control: Today"
        : `Last control: ${kpis.lastControlDays}d ago`;

  const lastControlColor =
    kpis.lastControlDays === null || kpis.lastControlDays > 30
      ? "text-red-500"
      : kpis.lastControlDays > 7
        ? "text-yellow-500"
        : "text-green-500";

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="text-xl font-semibold">
        {getGreeting()}, {user.full_name ?? "Operator"}
      </h1>
      <p className="mb-4 text-sm text-neutral-500">{formatToday()}</p>

      {/* ── Refill Plan Review (pending operator approvals) ── */}
      <RefillPlanReview />

      {/* ── Section 1: Daily Refills ── */}
      <SectionCard
        title="Daily Refills"
        linkTo="/field/packing"
        tourId="daily-refills"
      >
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={n}
            label="To refill today"
            cardStyle={ratioCardStyle(n, n)}
            href="/field/packing"
          />
          <StatCard
            value={`${kpis.packedMachines}/${n}`}
            label="Machines packed"
            cardStyle={ratioCardStyle(kpis.packedMachines, n)}
            href="/field/packing"
          />
          <StatCard
            value={`${kpis.pickedUpMachines}/${n}`}
            label="Machines picked up"
            cardStyle={ratioCardStyle(kpis.pickedUpMachines, n)}
            href="/field/pickup"
          />
          <StatCard
            value={`${kpis.dispatchedMachines}/${n}`}
            label="Machines dispatched"
            cardStyle={ratioCardStyle(kpis.dispatchedMachines, n)}
            href="/field/dispatching"
          />
        </div>
      </SectionCard>

      {/* ── Section 2: Procurement ── */}
      <SectionCard
        title="Procurement"
        linkTo="/field/orders"
        tourId="procurement"
      >
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.openPOs}
            label="Open orders"
            subLabel="Pending delivery"
            cardStyle={kpiCardStyle(kpis.openPOs, "medium")}
            href="/field/orders"
          />
          <StatCard
            value={kpis.receivedToday}
            label="Received today"
            cardStyle={kpiCardStyle(0, "low")}
            href="/field/receiving"
          />
          <Link
            href="/field/orders/new"
            className="col-span-2 flex items-center justify-center gap-2 rounded-xl border-2 border-dashed border-blue-200 bg-blue-50 py-3 text-sm font-medium text-blue-600 transition-colors hover:bg-blue-100"
          >
            + New Purchase Order
          </Link>
        </div>
      </SectionCard>

      {/* ── Section 3: Inventory ── */}
      <SectionCard
        title="Inventory"
        linkTo="/field/inventory"
        tourId="inventory"
        rightContent={
          <span className={`text-xs font-medium ${lastControlColor}`}>
            {lastControlLabel}
          </span>
        }
      >
        <p className="mb-2 mt-1 text-xs text-gray-400">Warehouse stock</p>
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.expired}
            label="Expired"
            cardStyle={kpiCardStyle(kpis.expired, "critical")}
            href="/field/inventory"
          />
          <StatCard
            value={kpis.expiring3}
            label="< 3 days"
            cardStyle={kpiCardStyle(kpis.expiring3, "high")}
            href="/field/inventory"
          />
          <StatCard
            value={kpis.expiring7}
            label="< 7 days"
            cardStyle={kpiCardStyle(kpis.expiring7, "medium")}
            href="/field/inventory"
          />
          <StatCard
            value={kpis.expiring30}
            label="< 30 days"
            cardStyle={kpiCardStyle(kpis.expiring30, "low")}
            href="/field/inventory"
          />
        </div>

        <p className="mb-2 mt-4 text-xs text-gray-400">Machine stock</p>
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={podKpis.expired}
            label="Expired"
            cardStyle={kpiCardStyle(podKpis.expired, "critical")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring3}
            label="< 3 days"
            cardStyle={kpiCardStyle(podKpis.expiring3, "high")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring7}
            label="< 7 days"
            cardStyle={kpiCardStyle(podKpis.expiring7, "medium")}
            href="/field/pod-inventory"
          />
          <StatCard
            value={podKpis.expiring30}
            label="< 30 days"
            cardStyle={kpiCardStyle(podKpis.expiring30, "low")}
            href="/field/pod-inventory"
          />
        </div>
      </SectionCard>

      {/* ── Section 4: Field Operations ── */}
      <SectionCard
        title="Field Operations"
        linkTo="/field/trips"
        tourId="field-ops"
      >
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.openTasksCount}
            label="Driver tasks"
            cardStyle={
              kpis.openTasksCount > 0
                ? kpiCardStyle(kpis.openTasksCount, "high")
                : kpiCardStyle(0, "low")
            }
            href="/field/tasks"
          />
          <StatCard
            value={pickupReadyMachines}
            label="Ready to collect"
            cardStyle={ratioCardStyle(pickupReadyMachines, n)}
            href="/field/pickup"
          />
          <StatCard
            value={toDispatchMachines}
            label="To dispatch"
            cardStyle={ratioCardStyle(toDispatchMachines, n)}
            href="/field/dispatching"
          />
          <StatCard
            value={podKpis.expired}
            label="Expired in machines"
            cardStyle={kpiCardStyle(podKpis.expired, "critical")}
            href="/field/pod-inventory"
          />
          {kpis.pendingPodReviews > 0 && (
            <StatCard
              value={kpis.pendingPodReviews}
              label="Pod reviews pending"
              cardStyle={kpiCardStyle(kpis.pendingPodReviews, "high")}
              href="/field/inventory"
            />
          )}
        </div>
      </SectionCard>

      {/* ── Section 5: Configuration ── */}
      {configCounts && (
        <SectionCard
          title="Configuration"
          linkTo="/field/config"
          tourId="config"
        >
          <div className="grid grid-cols-2 gap-3">
            <StatCard
              value={configCounts.boonzProducts}
              label="Boonz products"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/boonz-products"
            />
            <StatCard
              value={configCounts.podProducts}
              label="Pod products"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/pod-products"
            />
            <StatCard
              value={configCounts.suppliers}
              label="Active suppliers"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/suppliers"
            />
            <StatCard
              value={configCounts.productMappings}
              label="Active mappings"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/product-mapping"
            />
            <StatCard
              value={configCounts.machinesCount}
              label="Machines"
              cardStyle={kpiCardStyle(0, "low")}
              href="/field/config/machines"
            />
          </div>
        </SectionCard>
      )}

      {/* Restart tour */}
      <div className="mt-2 pb-4 text-center">
        <button
          onClick={onRestartTour}
          className="text-xs text-neutral-400 underline underline-offset-2 hover:text-neutral-600 dark:hover:text-neutral-300"
        >
          Restart app tour
        </button>
      </div>
    </div>
  );
}

// ─── Main Page ────────────────────────────────────────────────────────────────

export default function FieldPage() {
  const [user, setUser] = useState<UserInfo | null>(null);
  const [whKpis, setWhKpis] = useState<WarehouseKpis | null>(null);
  const [driverKpis, setDriverKpis] = useState<DriverKpis | null>(null);
  const [podKpis, setPodKpis] = useState<PodExpiryKpis | null>(null);
  const [configCounts, setConfigCounts] = useState<ConfigCounts | null>(null);
  const [loading, setLoading] = useState(true);
  const [fetchError, setFetchError] = useState<string | null>(null);

  // Onboarding
  const [userId, setUserId] = useState<string | null>(null);
  const [showLanguagePicker, setShowLanguagePicker] = useState(false);
  const [showTour, setShowTour] = useState(false);
  const [tourLanguage, setTourLanguage] = useState<Language>("en");
  const [tourRole, setTourRole] = useState<Role>("field_staff");
  const hasCheckedOnboarding = useRef(false);

  const fetchData = useCallback(async () => {
    setFetchError(null);
    try {
      const supabase = createClient();
      const today = todayISO();

      const {
        data: { user: authUser },
      } = await supabase.auth.getUser();
      if (!authUser) return;

      setUserId(authUser.id);

      const { data: profile } = await supabase
        .from("user_profiles")
        .select("full_name, role, preferred_language, onboarding_complete")
        .eq("id", authUser.id)
        .single();

      const role = (profile?.role ?? "field_staff") as Role;
      const fullName = profile?.full_name ?? null;
      console.log("[field/page] role detected:", role);
      setUser({ full_name: fullName, role });
      setTourRole(role);

      // Onboarding check — only fire once per mount
      if (!hasCheckedOnboarding.current && !profile?.onboarding_complete) {
        hasCheckedOnboarding.current = true;
        const preferredLang = (profile?.preferred_language ??
          null) as Language | null;
        if (!preferredLang || preferredLang === "en") {
          setShowLanguagePicker(true);
        } else {
          setTourLanguage(preferredLang);
          setShowTour(true);
        }
      }

      const isAdmin = ADMIN_ROLES.includes(role);

      if (role === "warehouse" || isAdmin) {
        const todayPlus3 = addDays(today, 3);
        const todayPlus7 = addDays(today, 7);
        const todayPlus30 = addDays(today, 30);

        const [
          { data: dispatchData },
          { count: expiredCount },
          { count: expiring3Count },
          { count: expiring7Count },
          { count: expiring30Count },
          { data: openPOData },
          { count: activeInvCount },
          { count: expiryWeekCount },
          { count: receivedTodayCount },
          { data: lastControlRows },
          { data: openTasksData },
          { count: pendingPodReviewsCount },
          { data: podData },
        ] = await Promise.all([
          supabase
            .from("refill_dispatching")
            .select("machine_id, packed, picked_up, dispatched")
            .eq("dispatch_date", today)
            .eq("include", true),
          supabase
            .from("warehouse_inventory")
            .select("wh_inventory_id", { count: "exact", head: true })
            .eq("status", "Active")
            .lt("expiration_date", today),
          supabase
            .from("warehouse_inventory")
            .select("wh_inventory_id", { count: "exact", head: true })
            .eq("status", "Active")
            .gte("expiration_date", today)
            .lte("expiration_date", todayPlus3),
          supabase
            .from("warehouse_inventory")
            .select("wh_inventory_id", { count: "exact", head: true })
            .eq("status", "Active")
            .gt("expiration_date", todayPlus3)
            .lte("expiration_date", todayPlus7),
          supabase
            .from("warehouse_inventory")
            .select("wh_inventory_id", { count: "exact", head: true })
            .eq("status", "Active")
            .gt("expiration_date", todayPlus7)
            .lte("expiration_date", todayPlus30),
          supabase
            .from("purchase_orders")
            .select("po_id")
            .is("received_date", null),
          supabase
            .from("warehouse_inventory")
            .select("wh_inventory_id", { count: "exact", head: true })
            .eq("status", "Active"),
          supabase
            .from("warehouse_inventory")
            .select("wh_inventory_id", { count: "exact", head: true })
            .eq("status", "Active")
            .gte("expiration_date", today)
            .lte("expiration_date", todayPlus7),
          supabase
            .from("purchase_orders")
            .select("po_id", { count: "exact", head: true })
            .eq("received_date", today),
          supabase
            .from("inventory_control_log")
            .select("conducted_at")
            .order("conducted_at", { ascending: false })
            .limit(1),
          supabase
            .from("driver_tasks")
            .select("task_id")
            .in("status", ["pending", "acknowledged"]),
          supabase
            .from("pod_inventory_edits")
            .select("edit_id", { count: "exact", head: true })
            .eq("status", "pending"),
          supabase
            .from("pod_inventory")
            .select("expiration_date")
            .eq("status", "Active")
            .limit(10000),
        ]);

        // Group by machine, count completed status per-machine
        const machineMap = new Map<string, MachineStats>();
        for (const row of dispatchData ?? []) {
          const m = machineMap.get(row.machine_id) ?? {
            total: 0,
            packed: 0,
            pickedUp: 0,
            dispatched: 0,
          };
          m.total++;
          if (row.packed) m.packed++;
          if (row.picked_up) m.pickedUp++;
          if (row.dispatched) m.dispatched++;
          machineMap.set(row.machine_id, m);
        }
        const machines = Array.from(machineMap.values());
        const totalMachines = machines.length;
        const packedMachines = machines.filter(
          (m) => m.total > 0 && m.packed === m.total,
        ).length;
        const pickedUpMachines = machines.filter(
          (m) => m.total > 0 && m.pickedUp === m.total,
        ).length;
        const dispatchedMachines = machines.filter(
          (m) => m.total > 0 && m.dispatched === m.total,
        ).length;

        let lastControlDays: number | null = null;
        if (
          lastControlRows &&
          lastControlRows.length > 0 &&
          lastControlRows[0].conducted_at
        ) {
          const controlDate = new Date(lastControlRows[0].conducted_at);
          lastControlDays = Math.floor(
            (Date.now() - controlDate.getTime()) / 86400000,
          );
        }

        setWhKpis({
          machinesToday: totalMachines,
          packedMachines,
          pickedUpMachines,
          dispatchedMachines,
          expired: expiredCount ?? 0,
          expiring3: expiring3Count ?? 0,
          expiring7: expiring7Count ?? 0,
          expiring30: expiring30Count ?? 0,
          openPOs: new Set(openPOData?.map((r) => r.po_id) ?? []).size,
          receivedToday: receivedTodayCount ?? 0,
          activeItems: activeInvCount ?? 0,
          expiringWeek: expiryWeekCount ?? 0,
          lastControlDays,
          openTasksCount: openTasksData?.length ?? 0,
          pendingPodReviews: pendingPodReviewsCount ?? 0,
        });

        // Pod inventory expiry KPIs
        setPodKpis({
          expired:
            podData?.filter(
              (r) => r.expiration_date && r.expiration_date < today,
            ).length ?? 0,
          expiring3:
            podData?.filter(
              (r) =>
                r.expiration_date &&
                r.expiration_date >= today &&
                r.expiration_date <= todayPlus3,
            ).length ?? 0,
          expiring7:
            podData?.filter(
              (r) =>
                r.expiration_date &&
                r.expiration_date > todayPlus3 &&
                r.expiration_date <= todayPlus7,
            ).length ?? 0,
          expiring30:
            podData?.filter(
              (r) =>
                r.expiration_date &&
                r.expiration_date > todayPlus7 &&
                r.expiration_date <= todayPlus30,
            ).length ?? 0,
        });

        // Config counts — for admin roles and warehouse
        if (isAdmin || role === "warehouse") {
          const [
            { count: boonzCount },
            { count: podCount },
            { count: supplierCount },
            { count: mappingCount },
            { count: machineCount },
          ] = await Promise.all([
            supabase
              .from("boonz_products")
              .select("*", { count: "exact", head: true }),
            supabase
              .from("pod_products")
              .select("*", { count: "exact", head: true }),
            supabase
              .from("suppliers")
              .select("*", { count: "exact", head: true })
              .eq("status", "Active"),
            supabase
              .from("product_mapping")
              .select("*", { count: "exact", head: true })
              .eq("status", "Active"),
            supabase
              .from("machines")
              .select("*", { count: "exact", head: true }),
          ]);
          setConfigCounts({
            boonzProducts: boonzCount ?? 0,
            podProducts: podCount ?? 0,
            suppliers: supplierCount ?? 0,
            productMappings: mappingCount ?? 0,
            machinesCount: machineCount ?? 0,
          });
        }
      } else {
        // Driver KPIs
        const [{ data: dispatchData }, { data: openTasksData }] =
          await Promise.all([
            supabase
              .from("refill_dispatching")
              .select("machine_id, packed, picked_up, dispatched")
              .eq("dispatch_date", today)
              .eq("include", true),
            supabase
              .from("driver_tasks")
              .select("task_id")
              .in("status", ["pending", "acknowledged"]),
          ]);

        // Same machine-level counting as warehouse
        const machineMap = new Map<string, MachineStats>();
        for (const row of dispatchData ?? []) {
          const m = machineMap.get(row.machine_id) ?? {
            total: 0,
            packed: 0,
            pickedUp: 0,
            dispatched: 0,
          };
          m.total++;
          if (row.packed) m.packed++;
          if (row.picked_up) m.pickedUp++;
          if (row.dispatched) m.dispatched++;
          machineMap.set(row.machine_id, m);
        }
        const machines = Array.from(machineMap.values());

        const pickedUpMachines = machines.filter(
          (m) => m.total > 0 && m.pickedUp === m.total,
        ).length;
        const dispatchedMachines = machines.filter(
          (m) => m.total > 0 && m.dispatched === m.total,
        ).length;

        setDriverKpis({
          stopsToday: machineMap.size,
          pickedUpMachines,
          dispatchedMachines,
          openTasks: openTasksData?.length ?? 0,
        });

        // Pod inventory expiry KPIs
        const todayPlus3d = addDays(today, 3);
        const todayPlus7d = addDays(today, 7);
        const todayPlus30d = addDays(today, 30);

        const { data: podData } = await supabase
          .from("pod_inventory")
          .select("expiration_date")
          .eq("status", "Active")
          .limit(10000);

        setPodKpis({
          expired:
            podData?.filter(
              (r) => r.expiration_date && r.expiration_date < today,
            ).length ?? 0,
          expiring3:
            podData?.filter(
              (r) =>
                r.expiration_date &&
                r.expiration_date >= today &&
                r.expiration_date <= todayPlus3d,
            ).length ?? 0,
          expiring7:
            podData?.filter(
              (r) =>
                r.expiration_date &&
                r.expiration_date > todayPlus3d &&
                r.expiration_date <= todayPlus7d,
            ).length ?? 0,
          expiring30:
            podData?.filter(
              (r) =>
                r.expiration_date &&
                r.expiration_date > todayPlus7d &&
                r.expiration_date <= todayPlus30d,
            ).length ?? 0,
        });
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error("[field/page] fetchData error:", msg);
      setFetchError(msg);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  useEffect(() => {
    const REFETCH_COOLDOWN = 30_000;
    let lastFetch = Date.now();

    function handleVisibility() {
      if (document.visibilityState === "visible") {
        const now = Date.now();
        if (now - lastFetch > REFETCH_COOLDOWN) {
          lastFetch = now;
          fetchData();
        }
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
    };
  }, [fetchData]);

  async function handleLanguageConfirm(lang: Language) {
    setShowLanguagePicker(false);
    setTourLanguage(lang);
    setShowTour(true);
    if (userId) {
      const supabase = createClient();
      await supabase
        .from("user_profiles")
        .update({ preferred_language: lang })
        .eq("id", userId);
    }
  }

  async function handleTourComplete() {
    setShowTour(false);
    if (userId) {
      const supabase = createClient();
      await supabase
        .from("user_profiles")
        .update({ onboarding_complete: true })
        .eq("id", userId);
    }
  }

  async function handleRestartTour() {
    setShowTour(true);
    if (userId) {
      const supabase = createClient();
      await supabase
        .from("user_profiles")
        .update({ onboarding_complete: false })
        .eq("id", userId);
    }
  }

  if (loading)
    return (
      <div className="p-8 text-center text-sm text-gray-400">Loading...</div>
    );

  if (fetchError)
    return (
      <div className="p-8 text-center">
        <p className="text-sm font-medium text-red-600">Dashboard error</p>
        <p className="mt-1 font-mono text-xs text-red-400">{fetchError}</p>
      </div>
    );

  if (!user) return <Skeleton />;

  const isAdminRole = ADMIN_ROLES.includes(user.role);

  // field_staff → driver tour; all other roles → warehouse tour
  const tourSteps =
    tourRole === "field_staff"
      ? translations[tourLanguage].driverTour
      : translations[tourLanguage].warehouseTour;

  const tourOverlay = (
    <>
      {showLanguagePicker && (
        <LanguagePicker onComplete={handleLanguageConfirm} />
      )}
      {showTour && (
        <Tour
          steps={tourSteps}
          onComplete={handleTourComplete}
          onSkip={handleTourComplete}
        />
      )}
    </>
  );

  // ── Warehouse staff ──
  if (user.role === "warehouse") {
    if (!whKpis || !podKpis) return <Skeleton />;
    return (
      <>
        {tourOverlay}
        <WarehouseHome
          user={user}
          kpis={whKpis}
          podKpis={podKpis}
          onRestartTour={handleRestartTour}
          configCounts={configCounts ?? undefined}
        />
      </>
    );
  }

  // ── Operator / Admin ──
  if (isAdminRole) {
    if (!whKpis || !podKpis) return <Skeleton />;
    return (
      <>
        {tourOverlay}
        <OperatorAdminHome
          user={user}
          kpis={whKpis}
          podKpis={podKpis}
          onRestartTour={handleRestartTour}
          configCounts={configCounts}
        />
      </>
    );
  }

  // ── Driver / Field staff ──
  if (user.role === "field_staff") {
    if (!driverKpis || !podKpis) return <Skeleton />;
    return (
      <>
        {tourOverlay}
        <DriverHome
          user={user}
          kpis={driverKpis}
          podKpis={podKpis}
          onRestartTour={handleRestartTour}
        />
      </>
    );
  }

  // ── Unknown role fallback ──
  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <div className="text-center">
        <p className="text-sm text-neutral-500">
          Your account role (
          <code className="font-mono text-xs">{user.role}</code>) doesn&apos;t
          have a configured home page yet.
        </p>
        <p className="mt-1 text-xs text-neutral-400">
          Contact your administrator.
        </p>
      </div>
    </div>
  );
}
