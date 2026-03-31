export interface ExpiryStyle {
  badgeBg: string;
  badgeText: string;
  label: string;
  qtyColor: string;
}

export function getExpiryStyle(expiryDate: string | null): ExpiryStyle {
  if (!expiryDate)
    return { badgeBg: "", badgeText: "", label: "", qtyColor: "text-gray-700" };
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const exp = new Date(expiryDate + "T00:00:00");
  exp.setHours(0, 0, 0, 0);
  const diffDays = Math.floor(
    (exp.getTime() - today.getTime()) / (1000 * 60 * 60 * 24),
  );
  if (diffDays < 0)
    return {
      badgeBg: "bg-red-100",
      badgeText: "text-red-700",
      label: "Expired",
      qtyColor: "text-red-600",
    };
  if (diffDays === 0)
    return {
      badgeBg: "bg-red-50",
      badgeText: "text-red-400",
      label: "Today",
      qtyColor: "text-red-400",
    };
  if (diffDays <= 3)
    return {
      badgeBg: "bg-red-50",
      badgeText: "text-red-400",
      label: `${diffDays}d left`,
      qtyColor: "text-red-400",
    };
  if (diffDays <= 7)
    return {
      badgeBg: "bg-yellow-50",
      badgeText: "text-yellow-600",
      label: `${diffDays}d left`,
      qtyColor: "text-yellow-600",
    };
  if (diffDays <= 30)
    return {
      badgeBg: "bg-lime-50",
      badgeText: "text-lime-600",
      label: `${diffDays}d left`,
      qtyColor: "text-lime-600",
    };
  return {
    badgeBg: "bg-green-50",
    badgeText: "text-green-600",
    label: `${diffDays}d left`,
    qtyColor: "text-green-600",
  };
}
