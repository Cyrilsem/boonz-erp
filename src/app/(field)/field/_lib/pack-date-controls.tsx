"use client";

import { formatPackDate } from "./use-field-pack-date";

/**
 * PRD-111 — Today / Tomorrow segmented control for the packer surfaces.
 * Default is Today; Tomorrow is an explicit, visible choice.
 */
export function PackDateToggle({
  isTomorrow,
  setTomorrow,
  selectedDate,
}: {
  isTomorrow: boolean;
  setTomorrow: (next: boolean) => void;
  selectedDate: string;
}) {
  return (
    <div className="mb-3">
      <div
        role="group"
        aria-label="Packing date"
        className="inline-flex rounded-lg border border-neutral-200 bg-neutral-100 p-0.5 dark:border-neutral-800 dark:bg-neutral-900"
      >
        <button
          type="button"
          aria-pressed={!isTomorrow}
          onClick={() => setTomorrow(false)}
          className={`min-h-[44px] rounded-md px-4 text-sm font-semibold transition-colors ${
            !isTomorrow
              ? "bg-[#24544a] text-white"
              : "text-neutral-600 dark:text-neutral-400"
          }`}
        >
          Today
        </button>
        <button
          type="button"
          aria-pressed={isTomorrow}
          onClick={() => setTomorrow(true)}
          className={`min-h-[44px] rounded-md px-4 text-sm font-semibold transition-colors ${
            isTomorrow
              ? "bg-amber-600 text-white"
              : "text-neutral-600 dark:text-neutral-400"
          }`}
        >
          Tomorrow
        </button>
      </div>
      <p className="mt-1 font-mono text-xs text-neutral-400">{selectedDate}</p>
    </div>
  );
}

/**
 * PRD-111 — persistent amber warning shown on EVERY tomorrow view. Packing the
 * wrong day is silent and expensive, so the banner never collapses or auto-hides.
 */
export function PackAheadBanner({ selectedDate }: { selectedDate: string }) {
  return (
    <div
      role="status"
      className="mb-4 rounded-lg border border-amber-400 bg-amber-50 px-3 py-2.5 text-sm dark:border-amber-700 dark:bg-amber-950/30"
    >
      <p className="font-semibold text-amber-900 dark:text-amber-200">
        ⚠ Packing for TOMORROW — {selectedDate}
      </p>
      <p className="mt-0.5 text-xs text-amber-800 dark:text-amber-300">
        {formatPackDate(selectedDate)}. Today&apos;s plan is not shown on this
        screen.
      </p>
    </div>
  );
}
