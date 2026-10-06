"use client";

export default function LogoutButton() {
  function handleSignOut() {
    // /logout clears the Supabase session AND the signed boonz_role cookie.
    window.location.assign("/logout");
  }

  return (
    <button
      onClick={handleSignOut}
      style={{
        fontSize: 12,
        color: "#8892A4",
        background: "transparent",
        border: "1px solid #1E2D42",
        borderRadius: 6,
        padding: "6px 14px",
        cursor: "pointer",
      }}
    >
      Sign out
    </button>
  );
}
