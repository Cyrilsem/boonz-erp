import Link from "next/link";

// PRD-140 Item 3: Settings hub. Replaces the placeholder with a real list;
// "Users" is the only entry for now.
export default function SettingsPage() {
  return (
    <div className="p-8 max-w-5xl">
      <div className="mb-8">
        <h1
          style={{
            fontFamily: "'Plus Jakarta Sans', sans-serif",
            fontWeight: 800,
            fontSize: 28,
            letterSpacing: "-0.02em",
            color: "#0a0a0a",
            margin: 0,
          }}
        >
          Settings
        </h1>
        <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
          Boonz ERP
        </p>
      </div>

      <Link
        href="/app/settings/users"
        style={{
          display: "block",
          background: "white",
          border: "1px solid #e8e4de",
          borderLeft: "4px solid #24544a",
          borderRadius: 12,
          padding: "24px 28px",
          maxWidth: 480,
          textDecoration: "none",
        }}
      >
        <h2
          style={{
            fontWeight: 700,
            fontSize: 16,
            marginBottom: 4,
            color: "#0a0a0a",
          }}
        >
          Users
        </h2>
        <p style={{ color: "#6b6860", fontSize: 13, margin: 0 }}>
          Create users, change roles, grant or deny individual areas, reset
          passwords, disable accounts.
        </p>
      </Link>
    </div>
  );
}
