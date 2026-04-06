import LogoutButton from "./logout-button";

export default function ConsumersVoxLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div style={{ minHeight: "100vh", background: "#080C12" }}>
      <header
        style={{
          borderBottom: "1px solid #1E2D42",
          background: "#0A0E1A",
          padding: "16px 24px",
        }}
      >
        <div
          style={{
            maxWidth: 1280,
            margin: "0 auto",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <div>
            <div
              style={{
                fontSize: 18,
                fontWeight: 700,
                color: "#E8EDF5",
                letterSpacing: "-0.02em",
              }}
            >
              BOONZ <span style={{ color: "#8892A4", fontWeight: 400 }}>×</span>{" "}
              VOX Cinemas
            </div>
            <div
              style={{
                fontSize: 10,
                textTransform: "uppercase",
                letterSpacing: "0.15em",
                color: "#5A6A80",
                fontWeight: 600,
                marginTop: 2,
              }}
            >
              Smart Vending · Performance Dashboard
            </div>
          </div>
          <LogoutButton />
        </div>
      </header>
      <main>{children}</main>
    </div>
  );
}
