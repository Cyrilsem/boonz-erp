"use client";

import { useCallback } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { getDubaiDate } from "@/lib/utils/date";

/**
 * PRD-111 — pack-ahead date state for the field PWA.
 *
 * The warehouse manager works exclusively on /field and had no way to see a
 * plan pushed for tomorrow (every field surface was pinned to getDubaiDate()).
 * This hook is the single source of the packer-facing dispatch date. Exactly
 * two values, today and tomorrow — no arbitrary picker, no past dates (packing
 * a stale plan is the risk this deliberately forecloses).
 *
 * Scope: /field/packing, /field/packing/[machineId], /field/not-filled only.
 * Never wire this into pickup / dispatching / trips (driver-facing).
 */

/**
 * Tomorrow in Dubai as YYYY-MM-DD.
 *
 * Same derivation as RefillPageClient.tsx (the admin /refill toggle): take the
 * Dubai date string, +1 day, back to YYYY-MM-DD. getDubaiDate() owns the
 * timezone math — do not reimplement it here.
 */
export function dubaiTomorrow(): string {
  const d = new Date(getDubaiDate());
  d.setDate(d.getDate() + 1);
  return d.toISOString().split("T")[0];
}

export interface FieldPackDate {
  /** The dispatch_date every query / RPC arg on the packing surfaces must use. */
  selectedDate: string;
  isTomorrow: boolean;
  setTomorrow: (next: boolean) => void;
  /**
   * "?d=tomorrow" or "" — append to intra-packing links so the selected date
   * survives list -> detail -> back navigation and hard refresh.
   */
  dateQuery: string;
}

export function useFieldPackDate(): FieldPackDate {
  const searchParams = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();

  // URL is the store (no localStorage): a shared/refreshed link keeps the date.
  const isTomorrow = searchParams?.get("d") === "tomorrow";

  const setTomorrow = useCallback(
    (next: boolean) => {
      const params = new URLSearchParams(searchParams?.toString() ?? "");
      if (next) {
        params.set("d", "tomorrow");
      } else {
        params.delete("d");
      }
      const qs = params.toString();
      router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
    },
    [pathname, router, searchParams],
  );

  return {
    selectedDate: isTomorrow ? dubaiTomorrow() : getDubaiDate(),
    isTomorrow,
    setTomorrow,
    dateQuery: isTomorrow ? "?d=tomorrow" : "",
  };
}

/** "Sunday 9 August 2026" — banner/empty-state copy so the day is unmissable. */
export function formatPackDate(dateStr: string): string {
  return new Date(dateStr + "T00:00:00").toLocaleDateString("en-GB", {
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  });
}
