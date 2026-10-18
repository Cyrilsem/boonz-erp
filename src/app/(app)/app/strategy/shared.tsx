"use client";

// PRD-142a: shared types, formatters and small UI pieces for /app/strategy.

import type { ReactNode } from "react";

export type Population = "boonz" | "partner" | "all";

export const MACHINE_POSTURES = [
  "PROTECT_GROW",
  "FIX_MIX",
  "WATCH_ADAPT",
  "NOT_FLIPPABLE",
] as const;
export type MachinePosture = (typeof MACHINE_POSTURES)[number];

export const POSTURE_LABEL: Record<string, string> = {
  PROTECT_GROW: "Protect and grow",
  FIX_MIX: "Fix the mix",
  WATCH_ADAPT: "Watch and adapt",
  NOT_FLIPPABLE: "Not flippable",
};

export const POSTURE_COLOR: Record<string, string> = {
  PROTECT_GROW: "#15803d",
  FIX_MIX: "#b45309",
  WATCH_ADAPT: "#1d4ed8",
  NOT_FLIPPABLE: "#dc2626",
};

export const PRODUCT_POSTURES = [
  "GROW",
  "HOLD",
  "RESOURCE",
  "DRAIN",
  "EXIT",
] as const;

export const PLAYBOOK_ORDER = [
  "DOUBLE_DOWN",
  "PROTECT",
  "MISSED_THE_WAVE",
  "COOLED_OFF",
  "REDUCE_REPLACE",
  "INCUBATE",
  "EXIT",
] as const;

export const PLAYBOOK_LABEL: Record<string, string> = {
  DOUBLE_DOWN: "Double down",
  PROTECT: "Protect",
  MISSED_THE_WAVE: "Missed the wave",
  COOLED_OFF: "Cooled off",
  REDUCE_REPLACE: "Reduce and replace",
  INCUBATE: "Incubate",
  EXIT: "Exit",
  SUPERSEDED: "Superseded",
  ANOMALY: "Anomaly",
};

export const PLAYBOOK_COLOR: Record<string, string> = {
  DOUBLE_DOWN: "#15803d",
  PROTECT: "#24544a",
  MISSED_THE_WAVE: "#dc2626",
  COOLED_OFF: "#b5804a",
  REDUCE_REPLACE: "#e1b460",
  INCUBATE: "#1d4ed8",
  EXIT: "#6b6860",
  SUPERSEDED: "#a3a09a",
  ANOMALY: "#a3a09a",
};

// Archetype colours from the ERP chart palette, then status colours.
const ARCHETYPE_PALETTE = [
  "#24544a",
  "#e1b460",
  "#7ba69b",
  "#b5804a",
  "#3d7068",
  "#1d4ed8",
  "#dc2626",
  "#6b6860",
  "#d9c9a3",
  "#15803d",
];
export function archetypeColor(code: string | null | undefined, all: string[]) {
  if (!code) return "#a3a09a";
  const i = all.indexOf(code);
  return ARCHETYPE_PALETTE[(i < 0 ? 0 : i) % ARCHETYPE_PALETTE.length];
}

// Maturity: single-hue ordinal ramp (Boonz green), lightest = newest.
export const MATURITY_COLOR: Record<string, string> = {
  New: "#b9d3cc",
  Growing: "#7ba69b",
  Established: "#3d7068",
  Mature: "#1d4439",
};

export function aed(v: number | null | undefined, digits = 0): string {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return "–";
  return `AED ${Number(v).toLocaleString("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  })}`;
}

export function num(v: number | null | undefined, digits = 1): string {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return "–";
  return Number(v).toLocaleString("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function pct(v: number | null | undefined, digits = 0): string {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return "–";
  return `${(Number(v) * 100).toFixed(digits)}%`;
}

export function Card({
  title,
  children,
  right,
}: {
  title?: string;
  children: ReactNode;
  right?: ReactNode;
}) {
  return (
    <section
      className="rounded-xl p-4"
      style={{ background: "var(--surface)", border: "1px solid var(--line)" }}
    >
      {(title || right) && (
        <div className="mb-3 flex items-center justify-between gap-3">
          {title && (
            <h3
              className="text-sm font-semibold"
              style={{ color: "var(--ink)" }}
            >
              {title}
            </h3>
          )}
          {right}
        </div>
      )}
      {children}
    </section>
  );
}

export function Kpi({
  label,
  value,
  sub,
}: {
  label: string;
  value: ReactNode;
  sub?: ReactNode;
}) {
  return (
    <div
      className="rounded-xl px-4 py-3"
      style={{ background: "var(--surface)", border: "1px solid var(--line)" }}
    >
      <div
        className="text-[11px] uppercase tracking-wide"
        style={{ color: "var(--muted)" }}
      >
        {label}
      </div>
      <div
        className="mt-1 text-lg font-semibold"
        style={{ color: "var(--ink)" }}
      >
        {value}
      </div>
      {sub && (
        <div className="text-xs" style={{ color: "var(--muted)" }}>
          {sub}
        </div>
      )}
    </div>
  );
}

export function Pill({
  children,
  color,
  outline,
  title,
}: {
  children: ReactNode;
  color: string;
  outline?: boolean;
  title?: string;
}) {
  return (
    <span
      title={title}
      className="inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-medium"
      style={
        outline
          ? { border: `1px dashed ${color}`, color }
          : { background: color, color: "white" }
      }
    >
      {children}
    </span>
  );
}

export function Segmented<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange: (v: T) => void;
}) {
  return (
    <div
      className="inline-flex overflow-hidden rounded-lg"
      style={{ border: "1px solid var(--line)" }}
    >
      {options.map((o) => (
        <button
          key={o.value}
          onClick={() => onChange(o.value)}
          className="px-3 py-1.5 text-xs font-medium"
          style={
            o.value === value
              ? { background: "var(--brand)", color: "white" }
              : { background: "var(--surface)", color: "var(--muted)" }
          }
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Drawer({
  open,
  onClose,
  title,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: ReactNode;
  children: ReactNode;
}) {
  if (!open) return null;
  return (
    <div
      className="fixed inset-0 z-50 flex justify-end"
      role="dialog"
      aria-modal="true"
    >
      <button
        aria-label="Close"
        className="absolute inset-0"
        style={{ background: "rgba(10,10,10,0.35)" }}
        onClick={onClose}
      />
      <div
        className="relative h-full w-full max-w-5xl overflow-y-auto p-5"
        style={{ background: "var(--surface-2)" }}
      >
        <div className="mb-4 flex items-start justify-between gap-4">
          <div
            className="text-lg font-semibold"
            style={{ color: "var(--ink)" }}
          >
            {title}
          </div>
          <button
            onClick={onClose}
            className="rounded-lg px-3 py-1 text-sm"
            style={{
              border: "1px solid var(--line)",
              background: "var(--surface)",
            }}
          >
            Close
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

export function sortRows<T>(rows: T[], key: keyof T | null, dir: 1 | -1): T[] {
  if (!key) return rows;
  return [...rows].sort((a, b) => {
    const av = a[key] as unknown;
    const bv = b[key] as unknown;
    if (av === bv) return 0;
    if (av === null || av === undefined) return 1;
    if (bv === null || bv === undefined) return -1;
    if (typeof av === "number" && typeof bv === "number")
      return (av - bv) * dir;
    return String(av).localeCompare(String(bv)) * dir;
  });
}
