"use client";

// PRD-116 item H: shared in-app replacement for window.prompt/window.confirm.
// Native dialogs block the render thread, can't be styled/tested, and on some
// mobile browsers silently return null instead of prompting — callers had no
// truthful way to tell "cancelled" from "not supported". This covers the three
// shapes those call sites needed: a plain yes/no confirm, a reason-only note,
// and a value (qty/price) collected together with its reason.

import { useEffect, useState } from "react";

interface PromptModalProps {
  title: string;
  description?: string;
  mode: "confirm" | "reason" | "reason-with-value";
  valueLabel?: string;
  valueType?: "text" | "number";
  defaultValue?: string;
  minReasonLength?: number;
  reasonPlaceholder?: string;
  reasonOptional?: boolean;
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
  busy?: boolean;
  error?: string | null;
  onCancel: () => void;
  onConfirm: (result: {
    value: string;
    reason: string;
  }) => void | Promise<void>;
}

export default function PromptModal({
  title,
  description,
  mode,
  valueLabel,
  valueType = "text",
  defaultValue = "",
  minReasonLength = 0,
  reasonPlaceholder = "Reason…",
  reasonOptional = false,
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
  destructive = false,
  busy = false,
  error = null,
  onCancel,
  onConfirm,
}: PromptModalProps) {
  const [value, setValue] = useState(defaultValue);
  const [reason, setReason] = useState("");

  useEffect(() => {
    setValue(defaultValue);
  }, [defaultValue]);

  const reasonNeeded = mode !== "confirm" && !reasonOptional;
  const reasonOk = !reasonNeeded || reason.trim().length >= minReasonLength;
  const canSubmit = mode === "confirm" ? true : reasonOk;

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={title}
      onClick={() => !busy && onCancel()}
      className="fixed inset-0 z-[300] flex items-center justify-center bg-black/45 p-4"
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-full max-w-md rounded-xl bg-white p-6 shadow-2xl dark:bg-neutral-900"
      >
        <div className="text-lg font-extrabold tracking-tight text-neutral-900 dark:text-neutral-50">
          {title}
        </div>
        {description && (
          <div className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
            {description}
          </div>
        )}

        {mode === "reason-with-value" && (
          <label className="mt-4 block text-xs font-semibold text-neutral-700 dark:text-neutral-300">
            {valueLabel ?? "Value"}
            <input
              type={valueType}
              value={value}
              onChange={(e) => setValue(e.target.value)}
              autoFocus
              className="mt-1.5 w-full rounded-lg border border-neutral-300 px-2.5 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800"
            />
          </label>
        )}

        {mode !== "confirm" && (
          <label className="mt-4 block text-xs font-semibold text-neutral-700 dark:text-neutral-300">
            Reason
            {minReasonLength > 0
              ? ` (min ${minReasonLength} chars)`
              : reasonOptional
                ? " (optional)"
                : ""}
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder={reasonPlaceholder}
              rows={3}
              autoFocus={mode === "reason"}
              className="mt-1.5 w-full resize-none rounded-lg border border-neutral-300 px-2.5 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800"
            />
          </label>
        )}

        {error && (
          <div className="mt-3 rounded-lg border border-rose-200 bg-rose-50 px-2.5 py-2 text-xs text-rose-700 dark:border-rose-900 dark:bg-rose-950/30 dark:text-rose-300">
            {error}
          </div>
        )}

        <div className="mt-5 flex justify-end gap-2">
          <button
            type="button"
            onClick={onCancel}
            disabled={busy}
            className="rounded-lg border border-neutral-300 bg-white px-4 py-2 text-sm font-semibold text-neutral-700 hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            onClick={() => onConfirm({ value, reason: reason.trim() })}
            disabled={busy || !canSubmit}
            className={`rounded-lg px-4 py-2 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-50 ${
              destructive
                ? "bg-rose-600 hover:bg-rose-700"
                : "bg-amber-500 hover:bg-amber-600"
            }`}
          >
            {busy ? "Working…" : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
