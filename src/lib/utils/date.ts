/**
 * Dubai timezone date utilities.
 *
 * Supabase CURRENT_DATE is UTC. Dubai is UTC+4, so between midnight and 4am
 * Dubai time, plain `new Date().toISOString().split('T')[0]` returns
 * yesterday's date and dispatch queries miss today's records.
 *
 * Always use getDubaiDate() wherever a "today" date string is needed for
 * dispatch_date filters or inserts.
 */

/**
 * Returns today's date as YYYY-MM-DD in the Asia/Dubai timezone (UTC+4).
 * Use this everywhere a "today" date is passed to dispatch_date filters.
 *
 * @example
 *   supabase.from("refill_dispatching").eq("dispatch_date", getDubaiDate())
 */
export function getDubaiDate(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Dubai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
  // en-CA locale returns YYYY-MM-DD format natively
}
