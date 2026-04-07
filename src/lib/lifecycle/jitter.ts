/**
 * Deterministic pseudo-random jitter from a string id.
 * Returns a value in [-amount, +amount].
 * Jitter is visual only — real values are preserved separately for tooltips.
 */
export function jitter(id: string, amount: number, salt = ""): number {
  let h = 0;
  const s = id + salt;
  for (let i = 0; i < s.length; i++) {
    h = (h << 5) - h + s.charCodeAt(i);
    h |= 0;
  }
  // Map h to [-1, 1]
  const norm = ((h % 1000) / 1000) * 2 - 1;
  return norm * amount;
}
