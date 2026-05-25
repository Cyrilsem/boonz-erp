"use client";
import { useEffect } from "react";

// PRD-UI-001: dark mode is disabled app-wide. ThemeToggle is kept as a
// component so existing call sites (field-header) do not need to be edited,
// but it renders nothing and actively scrubs any stale `.dark` class plus
// the persisted `theme` key from localStorage. If a proper dark mode is
// ever shipped, restore the prior implementation from git history.
export function ThemeToggle() {
  useEffect(() => {
    document.documentElement.classList.remove("dark");
    try {
      localStorage.removeItem("theme");
    } catch {
      // localStorage may throw in strict-Safari private mode; safe to ignore.
    }
  }, []);

  return null;
}
