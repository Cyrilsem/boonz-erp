// Single source of truth for the tracker/app owner identity.
// Used by the (app) layout to gate owner-only nav and by /tracker page gating.
// Compare case-insensitively: `(user.email ?? "").toLowerCase() === OWNER_EMAIL`.
export const OWNER_EMAIL = "cyrilsem@gmail.com";
