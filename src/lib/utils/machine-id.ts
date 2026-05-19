/**
 * Derives the short machine identifier shown under official_name across the
 * refill flow (planning, packing, pickup, dispatching, inventory).
 *
 * Source field: machines.adyen_store_code (e.g. "BOONZ_8625110705").
 * Display: last 4 digits of the numeric part — "0705" for the example above.
 *
 * Fleet coverage verified 2026-05-19: 102/102 machines populated, all in the
 * BOONZ_<digits> format. No NULL / off-format rows. Safe to render without
 * fallback copy.
 *
 * Convention reference: reference_device_number_derivation.md (2026-05-15).
 */
export function machineShortId(
  storeCode: string | null | undefined,
): string | null {
  if (!storeCode) return null;
  const digits = storeCode.replace(/^BOONZ_/, "").replace(/\D/g, "");
  if (digits.length === 0) return null;
  return digits.slice(-4);
}
