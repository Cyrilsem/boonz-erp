# PRD-056 transfer-aware packing — verification & close-out kit

FE is committed (`af9af0d`, branch `feat/prd-056-transfer-aware-packing-fe`): `tsc --noEmit`
clean, `next build` clean. This kit covers the steps that require a browser harness or a
backend apply, which cannot run in the headless agent environment (no Playwright/Chrome; the
backend apply is classifier-gated under the FE-only goal). Run these in a browser-capable
session.

## 1. Backend apply (PREREQUISITE — FE is non-functional without it)

The FE calls `confirm_packed_transferred`. Apply the two Cody-approved, replay-proven migrations
(already written, untracked in the repo root branch that holds them):

- `supabase/migrations/20260624100100_prd056_2_receive_dispatch_line_m2m_skip.sql`
- `supabase/migrations/20260624100200_prd056_3_confirm_packed_transferred.sql`

(`20260624100000_prd056_1_pack_outcome_packed_transferred.sql` — the enum value — is already
applied to prod.) Replay proof recorded: dest pod gains the unit, source pod archived, WH
total unchanged (no double-count), both legs `packed_transferred`, second confirm is a no-op.

## 2. Real-browser 375px a11y (the GREEN GATE)

Add `@playwright/test` (dev) + `npx playwright install chromium`, then run this spec against
`npm run dev`. Targets: no horizontal scroll, tap targets >= 44px, axe wcag2a/2aa clean,
screenshot each.

```ts
// e2e/prd056-transfer-packing.spec.ts
import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

test.use({ viewport: { width: 375, height: 812 } });

test("PRD-056 transfer row: only Packed & Transferred, no h-scroll, axe clean", async ({ page }) => {
  await page.goto("/field/packing/<machineId-with-an-m2m-transfer>");
  const card = page.locator("li", { hasText: "M2M Transfer" }).first();
  await expect(card).toBeVisible();

  // Only confirm option is Packed & Transferred; no Skip / Not Filled on transfer rows.
  await expect(card.getByRole("button", { name: /Packed & Transferred/i })).toBeVisible();
  await expect(card.getByRole("button", { name: /Skip|Not Filled/i })).toHaveCount(0);

  // Dest leg shows the Transfer-from tag.
  await expect(card.getByText(/Transfer from /i)).toBeVisible();

  // Tap target >= 44px.
  const btn = card.getByRole("button", { name: /Packed & Transferred/i });
  const box = await btn.boundingBox();
  expect(box!.height).toBeGreaterThanOrEqual(44);

  // No horizontal scroll at 375px.
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);

  // axe wcag2a/2aa.
  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa"])
    .analyze();
  expect(results.violations).toEqual([]);

  await page.screenshot({ path: "screenshots/prd056-transfer-375.png", fullPage: true });

  // Confirm -> done state.
  await btn.click();
  await expect(card.getByText(/Packed & Transferred — unit moved to destination/i)).toBeVisible();
});
```

## 3. Functional tests (from the team report)

1. Transfer row shows ONLY Packed & Transferred (Skip/Not Filled hidden). — covered above.
2. Confirm lands the unit in the DEST machine's `pod_inventory` — verify in SQL after click:
   `SELECT current_stock, expiration_date FROM pod_inventory WHERE machine_id='<dest>' AND status='Active' ORDER BY snapshot_at DESC LIMIT 1;`
   (backend replay already proved this; this re-confirms end-to-end through the UI).
3. Dest shows "Transfer from <source>" + one tap. — covered above.
4. Transferred add captures expiry — reuses the PRD-053-B per-expiry split UI (already on main).
5. A Not-Filled + transfer pair shows linked — surfaced via the transfer card grouping.

## 4. Deploy + prod smoke

Push `feat/prd-056-transfer-aware-packing-fe` to `main` ONLY after step 1 (apply) is done, so
the live field app never calls a missing writer. Vercel auto-deploys `boonz-erp.vercel.app`.
Smoke: open a machine with an M2M transfer at 375px, tap Packed & Transferred, confirm the dest
pod row appears.

## Status of the other team-report items (verified on origin/main)

- PRD-050 (4->2): already shipped (`4ea8afa`).
- PRD-053-A (stitch conservation): on prod; note prod stitch is `v28` (auto-conserve) vs git `v27`
  (detect+block gate) — reconcile.
- PRD-053-B (multi-expiry split FE): already shipped (`PendingRemoveApprovalsPanel.tsx` + split dialog).
