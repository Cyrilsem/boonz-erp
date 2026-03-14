'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'

const tabs = [
  { label: 'Trips', href: '/field', icon: '⊞' },
  { label: 'Pods', href: '/field/pods', icon: '◉' },
  { label: 'Inventory', href: '/field/inventory', icon: '▤' },
  { label: 'Profile', href: '/field/profile', icon: '⊙' },
]

export default function BottomTabs() {
  const pathname = usePathname()

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-10 flex border-t border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
      {tabs.map((tab) => {
        const active =
          tab.href === '/field'
            ? pathname === '/field'
            : pathname.startsWith(tab.href)

        return (
          <Link
            key={tab.href}
            href={tab.href}
            className={`flex min-h-[44px] flex-1 flex-col items-center justify-center gap-0.5 text-xs transition-colors ${
              active
                ? 'font-medium text-neutral-900 dark:text-neutral-100'
                : 'text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300'
            }`}
          >
            <span className="text-base">{tab.icon}</span>
            <span>{tab.label}</span>
          </Link>
        )
      })}
    </nav>
  )
}
