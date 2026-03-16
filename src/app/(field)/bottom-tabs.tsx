'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

interface Tab {
  label: string
  href: string
  icon: string
}

const fieldStaffTabs: Tab[] = [
  { label: 'Trips', href: '/field/trips', icon: '⊞' },
  { label: 'Pickup', href: '/field/pickup', icon: '◫' },
  { label: 'Dispatching', href: '/field/dispatching', icon: '▤' },
  { label: 'Profile', href: '/field/profile', icon: '⊙' },
]

const warehouseTabs: Tab[] = [
  { label: 'Packing', href: '/field/packing', icon: '◰' },
  { label: 'Receiving', href: '/field/receiving', icon: '◫' },
  { label: 'Expiry', href: '/field/expiry', icon: '⏱' },
  { label: 'Profile', href: '/field/profile', icon: '⊙' },
]

export default function BottomTabs() {
  const pathname = usePathname()
  const [tabs, setTabs] = useState<Tab[] | null>(null)

  useEffect(() => {
    async function fetchRole() {
      const supabase = createClient()
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) {
        console.log('[BottomTabs] No authenticated user, defaulting to field_staff nav')
        setTabs(fieldStaffTabs)
        return
      }

      const { data: profile, error } = await supabase
        .from('user_profiles')
        .select('role')
        .eq('id', user.id)
        .single()

      const role = profile?.role ?? 'field_staff'
      console.log('[BottomTabs] Fetched role:', role, error ? `(error: ${error.message})` : '')

      if (role === 'warehouse') {
        setTabs(warehouseTabs)
      } else {
        setTabs(fieldStaffTabs)
      }
    }

    fetchRole()
  }, [])

  if (!tabs) {
    return (
      <nav className="fixed bottom-0 left-0 right-0 z-10 flex h-[44px] border-t border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950" />
    )
  }

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-10 flex border-t border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
      {tabs.map((tab) => {
        const active = pathname.startsWith(tab.href)

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
