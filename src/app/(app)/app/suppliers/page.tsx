export default function SuppliersPage() {
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
          Suppliers
        </h1>
        <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
          Boonz ERP
        </p>
      </div>

      <div
        style={{
          background: "white",
          border: "1px solid #e8e4de",
          borderLeft: "4px solid #24544a",
          borderRadius: 12,
          padding: "32px 40px",
          maxWidth: 480,
        }}
      >
        <div
          style={{
            width: 40,
            height: 40,
            background: "#e6d1b8",
            borderRadius: 8,
            marginBottom: 16,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <span style={{ fontSize: 20 }}>🚧</span>
        </div>
        <h2
          style={{
            fontWeight: 700,
            fontSize: 18,
            marginBottom: 8,
            color: "#0a0a0a",
          }}
        >
          Coming soon
        </h2>
        <p style={{ color: "#6b6860", fontSize: 14, lineHeight: 1.6 }}>
          This section is being built. Check back soon.
        </p>
      </div>
    </div>
  );
}
