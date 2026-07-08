// PRD-087 R2 — merged into the unified Driver Requests page.
import { redirect } from "next/navigation";

export default function MergedRedirect() {
  redirect("/admin/driver-requests");
}
