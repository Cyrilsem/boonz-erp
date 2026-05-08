# Boonz ERP — Round 2 QA Remaining Fixes

Apply the following changes in order. Run `npx tsc --noEmit` and `npm run build` after completing all changes before committing. One commit per logical change using conventional format (`feat:` / `fix:` / `chore:`).

---

## F-04 — Low-stock badge on warehouse inventory batch rows

**File:** `src/app/(field)/field/inventory/page.tsx`

In the `ProductCard` component, inside the batch row `<div>` (the one with `key={batch.wh_inventory_id}`), add a low-stock badge immediately after the `<DaysBadge />` call, before the qty input:

```tsx
{
  batch.warehouse_stock <= 5 && batch.warehouse_stock > 0 && (
    <span className="shrink-0 rounded-full bg-orange-100 px-2 py-0.5 text-xs font-medium text-orange-700 dark:bg-orange-900 dark:text-orange-300">
      Low stock
    </span>
  );
}
```

Threshold: ≤ 5 units and > 0 (don't show "Low stock" on a zero/empty batch — those already show as 0).

---

## F-05 — CSV export for warehouse inventory

**File:** `src/app/(field)/field/inventory/page.tsx`

Add a "Export CSV" button to the page header toolbar (next to the existing filter/sort controls). When clicked it should export the **currently filtered and sorted** `rows` state (not raw data) as a CSV file.

### CSV columns (in order):

`Product Name, Category, Batch ID, Location, Stock, Expiry Date, Status`

### Implementation:

1. Add a `exportCSV` function inside `InventoryPage`:

```ts
function exportCSV() {
  const headers = [
    "Product Name",
    "Category",
    "Batch ID",
    "Location",
    "Stock",
    "Expiry Date",
    "Status",
  ];
  const csvRows = [
    headers.join(","),
    ...filteredRows.map((r) =>
      [
        `"${r.boonz_product_name.replace(/"/g, '""')}"`,
        `"${(r.product_category ?? "").replace(/"/g, '""')}"`,
        r.batch_id,
        `"${(r.wh_location ?? "").replace(/"/g, '""')}"`,
        r.warehouse_stock,
        r.expiration_date ?? "",
        r.status,
      ].join(","),
    ),
  ];
  const blob = new Blob([csvRows.join("\n")], { type: "text/csv" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `warehouse-inventory-${getDubaiDate()}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}
```

2. `filteredRows` is the already-filtered/sorted array that feeds the render. If it's currently inlined, extract it into a named `const filteredRows = useMemo(...)` so the export function can reference it.

3. Add the button somewhere near the top toolbar — e.g. next to the "Control Mode" toggle:

```tsx
<button
  onClick={exportCSV}
  className="rounded-lg border border-neutral-200 px-3 py-1.5 text-sm text-neutral-600 hover:bg-neutral-50 dark:border-neutral-700 dark:text-neutral-400 dark:hover:bg-neutral-800"
>
  Export CSV
</button>
```

---

## A-03 — In-app dark/light mode toggle

The app already supports dark mode via Tailwind's `dark:` classes. The toggle just needs to persist the preference.

### Files to touch:

- `src/app/layout.tsx` (or wherever the root `<html>` tag lives)
- `src/components/` — add `ThemeToggle.tsx`
- `src/app/(field)/field/components/field-header.tsx` — add toggle to header

### Steps:

1. **Create `src/components/ThemeToggle.tsx`:**

```tsx
"use client";
import { useEffect, useState } from "react";

export function ThemeToggle() {
  const [dark, setDark] = useState(false);

  useEffect(() => {
    const stored = localStorage.getItem("theme");
    const prefersDark = window.matchMedia(
      "(prefers-color-scheme: dark)",
    ).matches;
    const isDark = stored ? stored === "dark" : prefersDark;
    setDark(isDark);
    document.documentElement.classList.toggle("dark", isDark);
  }, []);

  function toggle() {
    const next = !dark;
    setDark(next);
    document.documentElement.classList.toggle("dark", next);
    localStorage.setItem("theme", next ? "dark" : "light");
  }

  return (
    <button
      onClick={toggle}
      aria-label="Toggle dark mode"
      className="rounded-lg p-1.5 text-neutral-500 hover:bg-neutral-100 dark:text-neutral-400 dark:hover:bg-neutral-800"
    >
      {dark ? "☀️" : "🌙"}
    </button>
  );
}
```

2. **Prevent flash on load** — in `src/app/layout.tsx`, add an inline script before any body content:

```tsx
<script
  dangerouslySetInnerHTML={{
    __html: `(function(){var t=localStorage.getItem('theme');var d=window.matchMedia('(prefers-color-scheme:dark)').matches;if(t==='dark'||(t===null&&d)){document.documentElement.classList.add('dark')}})()`,
  }}
/>
```

3. **Add `<ThemeToggle />` to `field-header.tsx`** — import and place it in the header's right-side action area.

---

## Verify

```bash
npx tsc --noEmit
npm run build
```

Both must pass cleanly before committing.

### Commit messages:

```
feat: add low-stock badge to inventory batch rows (F-04)
feat: add CSV export to warehouse inventory page (F-05)
feat: add dark/light mode toggle with localStorage persistence (A-03)
```
