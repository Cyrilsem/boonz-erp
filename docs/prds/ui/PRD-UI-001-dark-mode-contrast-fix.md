---
id: PRD-UI-001
title: Dark mode renders white text on white backgrounds across all pages
status: Done
severity: P0
reported: 2026-05-24
source: CS report — all pages unreadable after 8pm when OS switches to dark mode
routing: [Stax]
done_summary:
  commit: 6563d6e
  shipped_at: 2026-05-25
  changes:
    - AC#1 Force light mode globally — `src/app/globals.css` sets `:root { color-scheme: light; --background: #ffffff; --foreground: #171717; }` and removes the `@media (prefers-color-scheme: dark)` block.
    - AC#2 Tailwind darkMode neutralized — `globals.css` declares `@custom-variant dark (&:where(.dark, .dark *))` so leftover `dark:*` Tailwind classes only activate under an ancestor with `.dark` class, which is never set.
    - AC#3 Mobile color-scheme meta — `src/app/layout.tsx` head emits `<meta name="color-scheme" content="light" />` plus an inline script that scrubs any stale `.dark` class from `<html>` on mount, so mobile Safari / Chrome cannot apply native-control dark heuristics.
    - AC#4 Visual readability — CS-verified in production after the 2026-05-25 deploy. No dark-mode regression reports since shipping.
  files:
    - src/app/globals.css
    - src/app/layout.tsx
  verification:
    tsc: pass
    build: pass
    smoke_test: pass (CS verified post-deploy on 2026-05-25)
---

# PRD-UI-001 — Dark mode renders white text on white backgrounds

## Problem

After 8pm Dubai time, macOS/iOS auto-switches to dark mode. The app's `globals.css` respects `prefers-color-scheme: dark` and changes `--background` to `#0a0a0a` and `--foreground` to `#ededed`. However, the vast majority of components use **hardcoded Tailwind classes** (`bg-white`, `bg-gray-50`, `text-gray-900`, `text-black`) that do not respond to the CSS variable change. Result: dark body background from the CSS variable, but white card/table backgrounds and dark text from hardcoded classes, creating an inconsistent, hard-to-read UI.

Key pages affected: `/refill` (36 occurrences of `bg-white`/`bg-gray-*`), `/refill/RefillPlanningTab` (21), lifecycle page (18), pod-inventory (10), and 46 other files (208 total `bg-white`/`bg-gray-*` occurrences, 45 hardcoded dark text colors across 49 files).

## Root Cause

`globals.css` uses `@media (prefers-color-scheme: dark)` to set CSS custom properties, but components use hardcoded Tailwind color classes instead of those variables. The two systems are decoupled: the body goes dark while everything inside stays light-themed.

## Proposed Fix: Force Light Mode

This is an internal operations tool with 3-5 users. Properly implementing dark mode across 49 files with 250+ hardcoded color classes is high effort and low value. Instead, force the app to always render in light mode regardless of OS preference.

## Acceptance Criteria

### AC#1: Force light mode globally

In `globals.css`, remove or neutralize the dark mode media query so `--background` and `--foreground` always use the light values:

```css
:root {
  --background: #ffffff;
  --foreground: #171717;
}

/* REMOVED: @media (prefers-color-scheme: dark) block */
```

Additionally, add `color-scheme: light;` to `:root` to prevent the browser from applying its own dark mode heuristics to form elements, scrollbars, and native UI:

```css
:root {
  color-scheme: light;
  --background: #ffffff;
  --foreground: #171717;
}
```

### AC#2: Set Tailwind darkMode to disabled

In `tailwind.config.ts` (or `tailwind.config.js`), ensure dark mode is explicitly disabled so no `dark:` prefixed classes activate:

```js
module.exports = {
  darkMode: "class", // Only activate via .dark class, which we never add
  // ...
};
```

If the config already uses `'class'` mode, verify that no component or layout adds a `dark` class to `<html>` or `<body>`.

### AC#3: Add meta tag for mobile browsers

In the root layout (`layout.tsx`), add:

```html
<meta name="color-scheme" content="light" />
```

This prevents mobile Safari and Chrome from applying dark mode overrides.

### AC#4: Verify all pages are readable

After the fix, visually verify these key pages render correctly at all times of day:

- `/refill` (Refill Planning tab, both draft and pending modes)
- `/refill/drift`
- `/app/lifecycle`
- `/field/packing/[machineId]`
- `/field/inventory`
- `/field/orders`
- `/field/pod-inventory`
- `/field/dispatching`
- `/field/config/*` (all config sub-pages)
- Login and reset-password pages

Check for:

- All text readable (no white-on-white or dark-on-dark)
- All table headers, rows, and badges have proper contrast
- All modal/drawer backgrounds are opaque and light
- All input fields have visible borders and text
- Status badges (REFILL, REMOVE, ADD_NEW, etc.) remain visually distinct

## Implementation Notes

- The fix is 3 lines of CSS + 1 meta tag. Total scope: ~15 minutes.
- No component files need to change. The hardcoded `bg-white` and `text-gray-900` classes are correct for a light-only app.
- If dark mode is desired in the future, the proper approach is a full audit of all 49 affected files to replace hardcoded colors with CSS variable references or `dark:` prefixed Tailwind classes. That is a separate initiative.

## Files to Modify

1. `src/app/globals.css` — remove dark media query, add `color-scheme: light`
2. `src/app/layout.tsx` — add `<meta name="color-scheme" content="light" />`
3. `tailwind.config.ts` — verify `darkMode: 'class'`
