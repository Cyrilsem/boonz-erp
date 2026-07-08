// PRD-087 R1 — Machines and Pods were duplicate pages over the same
// `machines` table. The full editor now lives at /app/pods (single canonical
// page, per CS); this route only redirects so old links keep working.
import { redirect } from "next/navigation";

export default function MachinesRedirect() {
  redirect("/app/pods");
}
