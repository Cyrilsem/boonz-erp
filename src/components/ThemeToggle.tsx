"use client";
import { useEffect, useState } from "react";

// A-03: Persist the user's theme preference in localStorage; fall back to
// the system `prefers-color-scheme` on first visit. The inline bootstrap
// script in src/app/layout.tsx sets `.dark` on <html> before React mounts,
// which prevents a flash of light theme. This component keeps the toggle
// button in sync with the actual class state.
export function ThemeToggle() {
  const [dark, setDark] = useState(false);

  useEffect(() => {
    const stored = localStorage.getItem("theme");
    const prefersDark = window.matchMedia(
      "(prefers-color-scheme: dark)",
    ).matches;
    const isDark = stored ? stored === "dark" : prefersDark;
    setDark(isDark);
    document.documentElement.classList.toggle("dark", isDark);
  }, []);

  function toggle() {
    const next = !dark;
    setDark(next);
    document.documentElement.classList.toggle("dark", next);
    localStorage.setItem("theme", next ? "dark" : "light");
  }

  return (
    <button
      onClick={toggle}
      aria-label="Toggle dark mode"
      className="rounded-lg p-1.5 text-neutral-500 hover:bg-neutral-100 dark:text-neutral-400 dark:hover:bg-neutral-800"
    >
      {dark ? "☀️" : "🌙"}
    </button>
  );
}
